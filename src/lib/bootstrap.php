<?php
declare(strict_types=1);

const SCHEMA_VERSION = '1';

final class AppError extends RuntimeException
{
    public function __construct(string $message, public readonly int $status = 400)
    {
        parent::__construct($message);
    }
}

function nodeId(): string
{
    static $nodeId;
    if ($nodeId === null) {
        $nodeId = strtoupper(trim((string) getenv('NODE_ID')));
        if (!preg_match('/^[A-Z0-9_-]{1,32}$/', $nodeId)) {
            throw new RuntimeException('Premenná NODE_ID chýba alebo má neplatný formát.');
        }
    }
    return $nodeId;
}

function nodeLabel(): string
{
    return trim((string) getenv('NODE_LABEL')) ?: 'Uzol ' . nodeId();
}

function appVersion(): string
{
    return getenv('APP_VERSION') ?: 'dev';
}

function replicationToken(): string
{
    $token = (string) getenv('REPLICATION_TOKEN');
    if (strlen($token) < 16) {
        throw new RuntimeException('REPLICATION_TOKEN musí mať aspoň 16 znakov.');
    }
    return $token;
}

/** @return array<string, string> NODE_ID => base URL */
function peers(): array
{
    static $peers;
    if ($peers === null) {
        $peers = [];
        foreach (explode(',', (string) getenv('PEER_NODES')) as $entry) {
            if (!str_contains($entry, '=')) {
                continue;
            }
            [$node, $url] = array_map('trim', explode('=', $entry, 2));
            $node = strtoupper($node);
            if ($node !== '' && $node !== nodeId() && preg_match('#^https?://#', $url)) {
                $peers[$node] = rtrim($url, '/');
            }
        }
        ksort($peers);
    }
    return $peers;
}

function database(bool $reconnect = false): PDO
{
    static $connection;
    if ($reconnect) {
        $connection = null;
    }
    if ($connection instanceof PDO) {
        return $connection;
    }

    $dsn = sprintf(
        'mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4',
        getenv('DB_HOST') ?: '127.0.0.1',
        getenv('DB_PORT') ?: '3306',
        getenv('DB_NAME') ?: 'poruchy'
    );
    $connection = new PDO($dsn, getenv('DB_USER') ?: 'app', getenv('DB_PASSWORD') ?: '', [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES => false,
        PDO::ATTR_TIMEOUT => 3,
    ]);
    $connection->exec("SET time_zone = '+00:00'");
    ensureSchema($connection);

    return $connection;
}

function ensureSchema(PDO $connection): void
{
    static $ready = false;
    if ($ready) {
        return;
    }

    try {
        $version = $connection->query("SELECT meta_value FROM app_meta WHERE meta_key = 'schema_version'")->fetchColumn();
        if ($version === SCHEMA_VERSION) {
            $ready = true;
            return;
        }
    } catch (PDOException $error) {
        if ($error->getCode() !== '42S02') {
            throw $error;
        }
    }

    $statements = [
        "CREATE TABLE IF NOT EXISTS app_meta (
            meta_key VARCHAR(64) NOT NULL PRIMARY KEY,
            meta_value VARCHAR(255) NOT NULL,
            updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
        "CREATE TABLE IF NOT EXISTS poruchy (
            id CHAR(36) NOT NULL PRIMARY KEY,
            origin_node VARCHAR(32) NOT NULL,
            cislo_saly VARCHAR(32) NOT NULL,
            popis VARCHAR(1000) NOT NULL,
            stav VARCHAR(16) NOT NULL,
            version INT UNSIGNED NOT NULL,
            created_at DATETIME(3) NOT NULL,
            updated_at DATETIME(3) NOT NULL,
            deleted_at DATETIME(3) NULL,
            checksum CHAR(64) NOT NULL,
            stored_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
            KEY idx_poruchy_origin (origin_node),
            KEY idx_poruchy_updated (updated_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
        "CREATE TABLE IF NOT EXISTS outbox (
            id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            op_id CHAR(36) NOT NULL,
            peer_node VARCHAR(32) NOT NULL,
            record_id CHAR(36) NOT NULL,
            op_type VARCHAR(10) NOT NULL,
            version INT UNSIGNED NOT NULL,
            payload JSON NOT NULL,
            attempts INT UNSIGNED NOT NULL DEFAULT 0,
            next_attempt_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
            last_error VARCHAR(500) NULL,
            created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
            sent_at DATETIME(3) NULL,
            UNIQUE KEY uq_outbox_op_peer (op_id, peer_node),
            KEY idx_outbox_pending (peer_node, sent_at, next_attempt_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
        "CREATE TABLE IF NOT EXISTS inbox (
            op_id CHAR(36) NOT NULL PRIMARY KEY,
            from_node VARCHAR(32) NOT NULL,
            record_id CHAR(36) NOT NULL,
            op_type VARCHAR(10) NOT NULL,
            version INT UNSIGNED NOT NULL,
            result VARCHAR(20) NOT NULL DEFAULT 'received',
            received_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
            KEY idx_inbox_record (record_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
        "CREATE TABLE IF NOT EXISTS peer_state (
            peer_node VARCHAR(32) NOT NULL PRIMARY KEY,
            reachable TINYINT(1) NOT NULL DEFAULT 0,
            last_ok_at DATETIME(3) NULL,
            last_error VARCHAR(500) NULL,
            last_error_at DATETIME(3) NULL,
            last_push_at DATETIME(3) NULL,
            last_pull_at DATETIME(3) NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci",
    ];
    foreach ($statements as $statement) {
        $connection->exec($statement);
    }

    $connection->exec(
        "INSERT INTO app_meta (meta_key, meta_value) VALUES ('schema_version', '" . SCHEMA_VERSION . "'),
            ('duplicates_ignored', '0')
         ON DUPLICATE KEY UPDATE meta_value = IF(meta_key = 'schema_version', VALUES(meta_value), meta_value)"
    );
    $ready = true;
}

function utcNow(): string
{
    return (new DateTimeImmutable('now', new DateTimeZone('UTC')))->format('Y-m-d H:i:s.v');
}

function uuidV4(): string
{
    $bytes = random_bytes(16);
    $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
    $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($bytes), 4));
}

function encodeJson(mixed $value): string
{
    return json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
}

/** Štruktúrovaný log (JSON na stderr) – Docker ho zbiera pre centrálne logovanie. */
function logEvent(string $level, string $event, array $context = []): void
{
    $line = ['ts' => utcNow(), 'level' => $level, 'node' => getenv('NODE_ID') ?: '?', 'event' => $event] + $context;
    file_put_contents('php://stderr', encodeJson($line) . PHP_EOL);
}

function metaIncrement(PDO $connection, string $key): void
{
    $statement = $connection->prepare(
        "INSERT INTO app_meta (meta_key, meta_value) VALUES (:key, '1')
         ON DUPLICATE KEY UPDATE meta_value = CAST(meta_value AS UNSIGNED) + 1"
    );
    $statement->execute(['key' => $key]);
}

function metaSet(PDO $connection, string $key, string $value): void
{
    $statement = $connection->prepare(
        'INSERT INTO app_meta (meta_key, meta_value) VALUES (:key, :value)
         ON DUPLICATE KEY UPDATE meta_value = VALUES(meta_value)'
    );
    $statement->execute(['key' => $key, 'value' => $value]);
}
