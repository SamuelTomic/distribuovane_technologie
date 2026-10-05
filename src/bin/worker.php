<?php
declare(strict_types=1);

/*
 * Synchronizačný worker uzla (samostatný kontajner, rovnaký image ako aplikácia).
 * Každý tick: heartbeat → zistenie dostupnosti uzlov → push outboxu.
 * Každých PULL_INTERVAL sekúnd: anti-entropy pull podľa manifestu.
 */

require_once __DIR__ . '/../lib/sync.php';

$tickSeconds = max(1, (int) (getenv('SYNC_INTERVAL') ?: 2));
$pullInterval = max($tickSeconds, (int) (getenv('PULL_INTERVAL') ?: 15));
$running = true;
if (function_exists('pcntl_async_signals')) {
    pcntl_async_signals(true);
    pcntl_signal(SIGTERM, static function () use (&$running) { $running = false; });
    pcntl_signal(SIGINT, static function () use (&$running) { $running = false; });
}

logEvent('info', 'worker_started', ['peers' => peers(), 'tick_s' => $tickSeconds, 'pull_s' => $pullInterval]);
$lastPull = [];
$connection = null;

while ($running) {
    $started = microtime(true);
    try {
        $connection ??= database(true);
        metaSet($connection, 'worker_heartbeat', utcNow());

        foreach (peers() as $peer => $url) {
            $probe = probePeer($connection, $peer, $url);
            if (!$probe['ok']) {
                continue;
            }
            pushToPeer($connection, $peer, $url);
            if ($probe['recovered'] || time() - ($lastPull[$peer] ?? 0) >= $pullInterval) {
                pullFromPeer($connection, $peer, $url);
                $lastPull[$peer] = time();
            }
        }
    } catch (PDOException $error) {
        logEvent('error', 'worker_db_error', ['error' => $error->getMessage()]);
        $connection = null;
    } catch (Throwable $error) {
        logEvent('error', 'worker_error', ['error' => $error->getMessage()]);
    }

    $sleep = $tickSeconds - (microtime(true) - $started);
    if ($running && $sleep > 0) {
        usleep((int) ($sleep * 1_000_000));
    }
}

logEvent('info', 'worker_stopped');
