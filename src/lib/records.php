<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

const RECORD_STATES = ['nova', 'riesi_sa', 'vyriesena'];
const RECORD_COLUMNS = 'id, origin_node, cislo_saly, popis, stav, version, created_at, updated_at, deleted_at, checksum';

/** Kanonická podoba záznamu – rovnaký vstup dá na každom uzle rovnaký checksum. */
function recordChecksum(array $record): string
{
    return hash('sha256', encodeJson([
        'id' => (string) $record['id'],
        'origin_node' => (string) $record['origin_node'],
        'cislo_saly' => (string) $record['cislo_saly'],
        'popis' => (string) $record['popis'],
        'stav' => (string) $record['stav'],
        'version' => (int) $record['version'],
        'created_at' => (string) $record['created_at'],
        'updated_at' => (string) $record['updated_at'],
        'deleted_at' => $record['deleted_at'] === null ? null : (string) $record['deleted_at'],
    ]));
}

function normalizeRecord(array $row): array
{
    $row['version'] = (int) $row['version'];
    $row['deleted_at'] = $row['deleted_at'] ?? null;
    unset($row['stored_at']);
    return $row;
}

function findRecord(PDO $connection, string $id, bool $forUpdate = false): ?array
{
    $statement = $connection->prepare(
        'SELECT ' . RECORD_COLUMNS . ' FROM poruchy WHERE id = :id' . ($forUpdate ? ' FOR UPDATE' : '')
    );
    $statement->execute(['id' => $id]);
    $row = $statement->fetch();
    return $row ? normalizeRecord($row) : null;
}

function listRecords(PDO $connection, bool $includeDeleted): array
{
    $sql = 'SELECT ' . RECORD_COLUMNS . ' FROM poruchy'
        . ($includeDeleted ? '' : ' WHERE deleted_at IS NULL')
        . ' ORDER BY created_at DESC, id';
    return array_map('normalizeRecord', $connection->query($sql)->fetchAll());
}

function saveRecordRow(PDO $connection, array $record): void
{
    $statement = $connection->prepare(
        'INSERT INTO poruchy (' . RECORD_COLUMNS . ')
         VALUES (:id, :origin_node, :cislo_saly, :popis, :stav, :version, :created_at, :updated_at, :deleted_at, :checksum)
         AS incoming
         ON DUPLICATE KEY UPDATE
            origin_node = incoming.origin_node, cislo_saly = incoming.cislo_saly, popis = incoming.popis,
            stav = incoming.stav, version = incoming.version, created_at = incoming.created_at,
            updated_at = incoming.updated_at, deleted_at = incoming.deleted_at, checksum = incoming.checksum'
    );
    $statement->execute(array_intersect_key($record, array_flip(explode(', ', RECORD_COLUMNS))));
}

function validateUserFields(array $input, ?array $current = null): array
{
    $fields = [];
    foreach (['cislo_saly' => 32, 'popis' => 1000] as $field => $maxLength) {
        if (!array_key_exists($field, $input) && $current !== null) {
            continue;
        }
        $value = trim((string) ($input[$field] ?? ''));
        if ($value === '' || mb_strlen($value) > $maxLength) {
            throw new AppError("Pole {$field} je povinné (max. {$maxLength} znakov).", 422);
        }
        $fields[$field] = $value;
    }
    if (array_key_exists('stav', $input) || $current === null) {
        $state = (string) ($input['stav'] ?? 'nova');
        if (!in_array($state, RECORD_STATES, true)) {
            throw new AppError('Neplatný stav. Povolené: ' . implode(', ', RECORD_STATES) . '.', 422);
        }
        $fields['stav'] = $state;
    }
    return $fields;
}

/** Zapíše operáciu do outboxu pre každý peer – v rovnakej transakcii ako zmena záznamu. */
function enqueueOperation(PDO $connection, string $opType, array $record): string
{
    $opId = uuidV4();
    $statement = $connection->prepare(
        'INSERT INTO outbox (op_id, peer_node, record_id, op_type, version, payload)
         VALUES (:op_id, :peer, :record_id, :op_type, :version, :payload)'
    );
    $payload = encodeJson($record);
    foreach (array_keys(peers()) as $peer) {
        $statement->execute([
            'op_id' => $opId,
            'peer' => $peer,
            'record_id' => $record['id'],
            'op_type' => $opType,
            'version' => $record['version'],
            'payload' => $payload,
        ]);
    }
    return $opId;
}

function createRecord(PDO $connection, array $input): array
{
    $fields = validateUserFields($input);
    $now = utcNow();
    $record = [
        'id' => uuidV4(),
        'origin_node' => nodeId(),
        'cislo_saly' => $fields['cislo_saly'],
        'popis' => $fields['popis'],
        'stav' => $fields['stav'],
        'version' => 1,
        'created_at' => $now,
        'updated_at' => $now,
        'deleted_at' => null,
    ];
    $record['checksum'] = recordChecksum($record);

    $connection->beginTransaction();
    try {
        saveRecordRow($connection, $record);
        $opId = enqueueOperation($connection, 'CREATE', $record);
        $connection->commit();
    } catch (Throwable $error) {
        $connection->rollBack();
        throw $error;
    }

    logEvent('info', 'record_created', ['record_id' => $record['id'], 'op_id' => $opId, 'version' => 1]);
    return $record;
}

/** Úprava alebo zmazanie (tombstone) – povolené iba vlastníkovi záznamu. */
function changeOwnedRecord(PDO $connection, string $id, ?array $input): array
{
    $connection->beginTransaction();
    try {
        $record = findRecord($connection, $id, true);
        if ($record === null) {
            throw new AppError('Záznam neexistuje.', 404);
        }
        if ($record['origin_node'] !== nodeId()) {
            throw new AppError("Záznam vlastní uzol {$record['origin_node']}; meniť ho môže iba vlastník.", 403);
        }
        if ($record['deleted_at'] !== null) {
            throw new AppError('Záznam už bol zmazaný.', 410);
        }

        $now = utcNow();
        if ($input === null) {
            $opType = 'DELETE';
            $record['deleted_at'] = $now;
        } else {
            $opType = 'UPDATE';
            $fields = validateUserFields($input, $record);
            if (array_intersect_assoc($fields, $record) === $fields) {
                $connection->commit();
                return $record;
            }
            $record = array_merge($record, $fields);
        }
        $record['version']++;
        $record['updated_at'] = $now;
        $record['checksum'] = recordChecksum($record);

        saveRecordRow($connection, $record);
        $opId = enqueueOperation($connection, $opType, $record);
        $connection->commit();
    } catch (Throwable $error) {
        if ($connection->inTransaction()) {
            $connection->rollBack();
        }
        throw $error;
    }

    logEvent('info', $opType === 'DELETE' ? 'record_deleted' : 'record_updated', [
        'record_id' => $id, 'op_id' => $opId, 'version' => $record['version'],
    ]);
    return $record;
}

function validateIncomingRecord(mixed $record): array
{
    if (!is_array($record)) {
        throw new AppError('Chýba záznam.', 422);
    }
    foreach (['id', 'origin_node', 'cislo_saly', 'popis', 'stav', 'created_at', 'updated_at', 'checksum'] as $field) {
        if (!isset($record[$field]) || !is_string($record[$field]) || $record[$field] === '') {
            throw new AppError("Záznam nemá platné pole {$field}.", 422);
        }
    }
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $record['id'])
        || !in_array($record['stav'], RECORD_STATES, true)
        || !is_int($record['version'] ?? null) || $record['version'] < 1
        || !(($record['deleted_at'] ?? null) === null || is_string($record['deleted_at']))) {
        throw new AppError('Záznam má neplatný formát.', 422);
    }
    $record['deleted_at'] ??= null;
    if (!hash_equals(recordChecksum($record), $record['checksum'])) {
        throw new AppError('Kontrolný súčet záznamu nesedí – údaje boli poškodené.', 422);
    }
    return $record;
}

/**
 * Uplatní stav záznamu od iného uzla.
 * Idempotencia: op_id v inboxe. Poradie: vyhráva vyššia verzia (staršie operácie sa ignorujú).
 * Pri zhodnej verzii a inom obsahu (nemalo by nastať – mení iba vlastník) rozhodne deterministicky checksum.
 */
function applyRemoteRecord(PDO $connection, array $record, string $fromNode, ?string $opId = null, string $opType = 'SYNC'): string
{
    $record = validateIncomingRecord($record);

    $connection->beginTransaction();
    try {
        if ($opId !== null) {
            $inbox = $connection->prepare(
                'INSERT IGNORE INTO inbox (op_id, from_node, record_id, op_type, version)
                 VALUES (:op_id, :from_node, :record_id, :op_type, :version)'
            );
            $inbox->execute([
                'op_id' => $opId, 'from_node' => $fromNode, 'record_id' => $record['id'],
                'op_type' => $opType, 'version' => $record['version'],
            ]);
            if ($inbox->rowCount() === 0) {
                metaIncrement($connection, 'duplicates_ignored');
                $connection->commit();
                logEvent('info', 'operation_duplicate', ['op_id' => $opId, 'from' => $fromNode, 'record_id' => $record['id']]);
                return 'duplicate';
            }
        }

        $local = findRecord($connection, $record['id'], true);
        if ($local === null || $record['version'] > $local['version']) {
            $result = 'applied';
        } elseif ($record['version'] === $local['version'] && $record['checksum'] !== $local['checksum']) {
            $result = strcmp($record['checksum'], $local['checksum']) > 0 ? 'conflict_resolved' : 'conflict_kept';
        } else {
            $result = 'stale';
        }

        if ($result === 'applied' || $result === 'conflict_resolved') {
            saveRecordRow($connection, $record);
        }
        if ($opId !== null) {
            $connection->prepare('UPDATE inbox SET result = :result WHERE op_id = :op_id')
                ->execute(['result' => $result, 'op_id' => $opId]);
        }
        $connection->commit();
    } catch (Throwable $error) {
        if ($connection->inTransaction()) {
            $connection->rollBack();
        }
        throw $error;
    }

    logEvent($result === 'applied' || $result === 'stale' ? 'info' : 'warning', 'operation_' . $result, [
        'op_id' => $opId, 'op_type' => $opType, 'from' => $fromNode,
        'record_id' => $record['id'], 'version' => $record['version'],
    ]);
    return $result;
}

/** Manifest = id, verzia, checksum každého záznamu + súhrnný hash na rýchle porovnanie uzlov. */
function buildManifest(PDO $connection): array
{
    $rows = $connection->query(
        'SELECT id, version, checksum, deleted_at IS NOT NULL AS deleted FROM poruchy ORDER BY id'
    )->fetchAll();
    $lines = [];
    $deleted = 0;
    foreach ($rows as &$row) {
        $row['version'] = (int) $row['version'];
        $row['deleted'] = (bool) $row['deleted'];
        $deleted += $row['deleted'] ? 1 : 0;
        $lines[] = "{$row['id']}:{$row['version']}:{$row['checksum']}";
    }
    unset($row);

    return [
        'node_id' => nodeId(),
        'count' => count($rows),
        'active' => count($rows) - $deleted,
        'deleted' => $deleted,
        'hash' => hash('sha256', implode("\n", $lines)),
        'records' => $rows,
    ];
}

/** Over integritu uložených dát – checksum každého riadku sa prepočíta. */
function verifyStoredChecksums(PDO $connection): array
{
    $broken = [];
    foreach ($connection->query('SELECT ' . RECORD_COLUMNS . ' FROM poruchy') as $row) {
        $row = normalizeRecord($row);
        if (!hash_equals(recordChecksum($row), $row['checksum'])) {
            $broken[] = $row['id'];
        }
    }
    return $broken;
}
