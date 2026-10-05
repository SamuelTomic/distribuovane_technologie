<?php
declare(strict_types=1);

require_once __DIR__ . '/../lib/bootstrap.php';

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');
try {
    database()->query('SELECT 1');
    echo 'ok';
} catch (Throwable $error) {
    http_response_code(503);
    echo 'unavailable';
}
