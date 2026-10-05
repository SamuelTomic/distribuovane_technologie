<?php
declare(strict_types=1);

require_once __DIR__ . '/records.php';

const PUSH_BATCH_SIZE = 100;
const MAX_BACKOFF_SECONDS = 30;
const ACCEPTED_RESULTS = ['applied', 'stale', 'duplicate', 'conflict_resolved', 'conflict_kept'];

/** HTTP volanie iného uzla. Nikdy nevyhodí výnimku – vráti ok/status/error. */
function peerRequest(string $method, string $url, ?array $body = null, int $timeout = 4): array
{
    $handle = curl_init($url);
    $headers = [
        'Accept: application/json',
        'X-Node-Id: ' . nodeId(),
        'X-Replication-Token: ' . replicationToken(),
    ];
    $options = [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 2,
        CURLOPT_TIMEOUT => $timeout,
        CURLOPT_FOLLOWLOCATION => false,
    ];
    if ($body !== null) {
        $options[CURLOPT_POSTFIELDS] = encodeJson($body);
        $headers[] = 'Content-Type: application/json';
    }
    $options[CURLOPT_HTTPHEADER] = $headers;
    curl_setopt_array($handle, $options);

    $raw = curl_exec($handle);
    $status = (int) curl_getinfo($handle, CURLINFO_HTTP_CODE);
    $curlError = curl_error($handle);
    curl_close($handle);

    $decoded = is_string($raw) ? json_decode($raw, true) : null;
    $ok = $raw !== false && $status >= 200 && $status < 300 && is_array($decoded);
    $error = null;
    if (!$ok) {
        $error = $raw === false || $status === 0
            ? 'Uzol je nedostupný: ' . ($curlError ?: 'bez odpovede')
            : 'HTTP ' . $status . (is_array($decoded) && isset($decoded['error']) ? ': ' . $decoded['error'] : '');
    }

    return ['ok' => $ok, 'status' => $status, 'body' => is_array($decoded) ? $decoded : null, 'error' => $error];
}

function updatePeerState(PDO $connection, string $peer, bool $reachable, ?string $error = null, ?string $touch = null): bool
{
    $previous = $connection->prepare('SELECT reachable FROM peer_state WHERE peer_node = :peer');
    $previous->execute(['peer' => $peer]);
    $wasReachable = $previous->fetchColumn();

    $touchSql = in_array($touch, ['last_push_at', 'last_pull_at'], true) ? ", {$touch} = UTC_TIMESTAMP(3)" : '';
    $connection->prepare(
        "INSERT INTO peer_state (peer_node, reachable) VALUES (:peer, :reachable)
         ON DUPLICATE KEY UPDATE reachable = VALUES(reachable)"
    )->execute(['peer' => $peer, 'reachable' => (int) $reachable]);
    if ($reachable) {
        $connection->prepare(
            "UPDATE peer_state SET last_ok_at = UTC_TIMESTAMP(3){$touchSql} WHERE peer_node = :peer"
        )->execute(['peer' => $peer]);
    } else {
        $connection->prepare(
            'UPDATE peer_state SET last_error = :error, last_error_at = UTC_TIMESTAMP(3) WHERE peer_node = :peer'
        )->execute(['peer' => $peer, 'error' => mb_substr((string) $error, 0, 500)]);
    }

    // Návrat: true ak sa uzol práve znova pripojil (predtým bol nedostupný).
    return $reachable && $wasReachable !== false && (int) $wasReachable === 0;
}

function markOutboxFailed(PDO $connection, array $ids, string $error): void
{
    if ($ids === []) {
        return;
    }
    $placeholders = implode(',', array_fill(0, count($ids), '?'));
    $statement = $connection->prepare(
        "UPDATE outbox SET attempts = attempts + 1,
            next_attempt_at = DATE_ADD(UTC_TIMESTAMP(3), INTERVAL LEAST(" . MAX_BACKOFF_SECONDS . ", POW(2, LEAST(attempts, 6))) SECOND),
            last_error = ?
         WHERE id IN ({$placeholders})"
    );
    $statement->execute([mb_substr($error, 0, 500), ...$ids]);
}

/** Odošle neodoslané operácie z outboxu jednému uzlu (at-least-once, opakovanie s backoffom). */
function pushToPeer(PDO $connection, string $peer, string $url, bool $ignoreBackoff = false): array
{
    $lock = $connection->prepare('SELECT GET_LOCK(:name, :timeout)');
    $lock->execute(['name' => 'push:' . $peer, 'timeout' => $ignoreBackoff ? 10 : 0]);
    if ((int) $lock->fetchColumn() !== 1) {
        return ['ok' => true, 'sent' => 0, 'skipped' => 'push už prebieha'];
    }

    $sent = 0;
    $result = ['ok' => true, 'error' => null];
    try {
        for ($batch = 0; $batch < 20; $batch++) {
            $select = $connection->prepare(
                'SELECT id, op_id, op_type, payload FROM outbox
                 WHERE peer_node = :peer AND sent_at IS NULL'
                . ($ignoreBackoff ? '' : ' AND next_attempt_at <= UTC_TIMESTAMP(3)')
                . ' ORDER BY id LIMIT ' . PUSH_BATCH_SIZE
            );
            $select->execute(['peer' => $peer]);
            $rows = $select->fetchAll();
            if ($rows === []) {
                break;
            }

            $ops = array_map(static fn (array $row) => [
                'op_id' => $row['op_id'],
                'op_type' => $row['op_type'],
                'record' => json_decode($row['payload'], true),
            ], $rows);
            $response = peerRequest('POST', $url . '/api/replicate', ['from_node' => nodeId(), 'ops' => $ops], 10);

            if (!$response['ok']) {
                markOutboxFailed($connection, array_column($rows, 'id'), $response['error']);
                $result = ['ok' => false, 'error' => $response['error']];
                logEvent('warning', 'push_failed', ['peer' => $peer, 'ops' => count($rows), 'error' => $response['error']]);
                break;
            }

            $byOp = array_column($response['body']['results'] ?? [], 'status', 'op_id');
            $acceptedIds = [];
            $rejectedIds = [];
            foreach ($rows as $row) {
                in_array($byOp[$row['op_id']] ?? null, ACCEPTED_RESULTS, true)
                    ? $acceptedIds[] = (int) $row['id']
                    : $rejectedIds[] = (int) $row['id'];
            }
            if ($acceptedIds !== []) {
                $placeholders = implode(',', array_fill(0, count($acceptedIds), '?'));
                $connection->prepare(
                    "UPDATE outbox SET sent_at = UTC_TIMESTAMP(3), attempts = attempts + 1, last_error = NULL
                     WHERE id IN ({$placeholders})"
                )->execute($acceptedIds);
                $sent += count($acceptedIds);
            }
            if ($rejectedIds !== []) {
                markOutboxFailed($connection, $rejectedIds, 'Peer operáciu odmietol.');
                $result = ['ok' => false, 'error' => 'Peer odmietol ' . count($rejectedIds) . ' operácií.'];
                logEvent('error', 'push_rejected', ['peer' => $peer, 'ops' => count($rejectedIds)]);
                break;
            }
        }
    } finally {
        $connection->prepare('SELECT RELEASE_LOCK(:name)')->execute(['name' => 'push:' . $peer]);
    }

    updatePeerState($connection, $peer, $result['ok'] || str_starts_with((string) $result['error'], 'Peer'), $result['error'], 'last_push_at');
    if ($sent > 0) {
        logEvent('info', 'push_done', ['peer' => $peer, 'sent' => $sent]);
    }
    return $result + ['sent' => $sent];
}

/** Anti-entropy: porovná manifest uzla s lokálnym a dotiahne chýbajúce alebo novšie záznamy. */
function pullFromPeer(PDO $connection, string $peer, string $url): array
{
    $response = peerRequest('GET', $url . '/api/manifest', null, 10);
    if (!$response['ok']) {
        updatePeerState($connection, $peer, false, $response['error']);
        return ['ok' => false, 'fetched' => 0, 'applied' => 0, 'error' => $response['error']];
    }

    $local = [];
    foreach (buildManifest($connection)['records'] as $row) {
        $local[$row['id']] = $row;
    }
    $missing = [];
    foreach ($response['body']['records'] ?? [] as $remote) {
        $mine = $local[$remote['id']] ?? null;
        if ($mine === null || $remote['version'] > $mine['version']
            || ($remote['version'] === $mine['version'] && $remote['checksum'] !== $mine['checksum'])) {
            $missing[] = $remote['id'];
        }
    }

    $applied = 0;
    $errors = [];
    foreach (array_chunk($missing, 200) as $ids) {
        $export = peerRequest('POST', $url . '/api/export', ['ids' => $ids], 10);
        if (!$export['ok']) {
            $errors[] = $export['error'];
            break;
        }
        foreach ($export['body']['records'] ?? [] as $record) {
            try {
                $status = applyRemoteRecord($connection, $record, $peer, null, 'PULL');
                $applied += in_array($status, ['applied', 'conflict_resolved'], true) ? 1 : 0;
            } catch (AppError $error) {
                $errors[] = $error->getMessage();
                logEvent('error', 'pull_record_rejected', ['peer' => $peer, 'record_id' => $record['id'] ?? null, 'error' => $error->getMessage()]);
            }
        }
    }

    $ok = $errors === [];
    updatePeerState($connection, $peer, true, null, 'last_pull_at');
    if ($missing !== []) {
        logEvent('info', 'pull_done', ['peer' => $peer, 'missing' => count($missing), 'applied' => $applied]);
    }
    return ['ok' => $ok, 'fetched' => count($missing), 'applied' => $applied, 'error' => $ok ? null : implode('; ', $errors)];
}

/** Zistí dostupnosť uzla. Pri obnovení spojenia okamžite uvoľní čakajúce operácie (zruší backoff). */
function probePeer(PDO $connection, string $peer, string $url): array
{
    $response = peerRequest('GET', $url . '/api/status', null, 3);
    $recovered = updatePeerState($connection, $peer, $response['ok'], $response['error']);
    if ($recovered) {
        $connection->prepare(
            'UPDATE outbox SET next_attempt_at = UTC_TIMESTAMP(3) WHERE peer_node = :peer AND sent_at IS NULL'
        )->execute(['peer' => $peer]);
        logEvent('info', 'peer_recovered', ['peer' => $peer]);
    } elseif (!$response['ok']) {
        logEvent('debug', 'peer_unreachable', ['peer' => $peer, 'error' => $response['error']]);
    }
    return $response + ['recovered' => $recovered];
}

/** Manuálna synchronizácia so všetkými uzlami – pri nedostupnom uzle bezpečne zlyhá, nič sa nestratí. */
function syncAll(PDO $connection): array
{
    $results = [];
    foreach (peers() as $peer => $url) {
        $probe = probePeer($connection, $peer, $url);
        if (!$probe['ok']) {
            $results[$peer] = ['ok' => false, 'error' => $probe['error']];
            continue;
        }
        $push = pushToPeer($connection, $peer, $url, true);
        $pull = pullFromPeer($connection, $peer, $url);
        $results[$peer] = [
            'ok' => $push['ok'] && $pull['ok'],
            'pushed' => $push['sent'],
            'pulled' => $pull['applied'],
            'error' => $push['error'] ?? $pull['error'],
        ];
    }
    $ok = !in_array(false, array_column($results, 'ok'), true);
    logEvent($ok ? 'info' : 'warning', 'manual_sync', ['ok' => $ok, 'peers' => $results]);
    return ['ok' => $ok, 'peers' => $results];
}

function localStatus(PDO $connection): array
{
    $manifest = buildManifest($connection);
    $pendingByPeer = array_fill_keys(array_keys(peers()), 0);
    foreach ($connection->query(
        'SELECT peer_node, COUNT(*) AS pending FROM outbox WHERE sent_at IS NULL GROUP BY peer_node'
    ) as $row) {
        $pendingByPeer[$row['peer_node']] = (int) $row['pending'];
    }
    $meta = $connection->query('SELECT meta_key, meta_value, updated_at FROM app_meta')->fetchAll(PDO::FETCH_UNIQUE);
    $heartbeat = $meta['worker_heartbeat']['meta_value'] ?? null;
    $heartbeatAge = $heartbeat === null ? null : time() - (int) strtotime($heartbeat . ' UTC');

    $peerStates = [];
    foreach ($connection->query('SELECT * FROM peer_state ORDER BY peer_node') as $row) {
        $peerStates[$row['peer_node']] = $row;
    }
    $peerList = [];
    foreach (peers() as $peer => $url) {
        $state = $peerStates[$peer] ?? [];
        $peerList[] = [
            'node_id' => $peer,
            'url' => $url,
            'reachable' => (bool) ($state['reachable'] ?? false),
            'last_ok_at' => $state['last_ok_at'] ?? null,
            'last_error' => $state['last_error'] ?? null,
            'last_push_at' => $state['last_push_at'] ?? null,
            'last_pull_at' => $state['last_pull_at'] ?? null,
            'pending' => $pendingByPeer[$peer] ?? 0,
        ];
    }

    return [
        'node_id' => nodeId(),
        'label' => nodeLabel(),
        'version' => appVersion(),
        'time' => utcNow(),
        'db' => 'ok',
        'worker' => ['heartbeat_at' => $heartbeat, 'age_s' => $heartbeatAge, 'alive' => $heartbeatAge !== null && $heartbeatAge < 30],
        'records' => ['total' => $manifest['count'], 'active' => $manifest['active'], 'deleted' => $manifest['deleted']],
        'manifest_hash' => $manifest['hash'],
        'outbox' => [
            'pending' => array_sum($pendingByPeer),
            'sent' => (int) $connection->query('SELECT COUNT(*) FROM outbox WHERE sent_at IS NOT NULL')->fetchColumn(),
        ],
        'inbox' => [
            'received' => (int) $connection->query('SELECT COUNT(*) FROM inbox')->fetchColumn(),
            'duplicates_ignored' => (int) ($meta['duplicates_ignored']['meta_value'] ?? 0),
        ],
        'peers' => $peerList,
    ];
}
