<?php
declare(strict_types=1);

// Health check workera: databáza dostupná a heartbeat nie je starší ako 30 s.
require_once __DIR__ . '/../lib/bootstrap.php';

try {
    $age = database()->query(
        "SELECT TIMESTAMPDIFF(SECOND, meta_value, UTC_TIMESTAMP(3)) FROM app_meta WHERE meta_key = 'worker_heartbeat'"
    )->fetchColumn();
    if ($age === false || (int) $age > 30) {
        fwrite(STDERR, "heartbeat missing or stale\n");
        exit(1);
    }
    echo "ok\n";
    exit(0);
} catch (Throwable $error) {
    fwrite(STDERR, $error->getMessage() . "\n");
    exit(1);
}
