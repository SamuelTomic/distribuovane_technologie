<?php
declare(strict_types=1);

require_once __DIR__ . '/../lib/sync.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

function respond(int $status, array $body): never
{
    http_response_code($status);
    echo encodeJson($body);
    exit;
}

function requestBody(): array
{
    $contentType = $_SERVER['CONTENT_TYPE'] ?? '';
    if (!str_starts_with(strtolower($contentType), 'application/json')) {
        throw new AppError('Očakáva sa Content-Type: application/json.', 415);
    }
    $body = json_decode(file_get_contents('php://input') ?: '', true);
    if (!is_array($body)) {
        throw new AppError('Neplatné JSON dáta.', 400);
    }
    return $body;
}

/** Endpointy medzi uzlami vyžadujú zdieľaný replikačný token. */
function requirePeerToken(): string
{
    $provided = $_SERVER['HTTP_X_REPLICATION_TOKEN'] ?? '';
    if (!hash_equals(replicationToken(), $provided)) {
        logEvent('warning', 'auth_rejected', ['remote' => $_SERVER['REMOTE_ADDR'] ?? '?', 'path' => $_SERVER['REQUEST_URI'] ?? '']);
        throw new AppError('Neplatný replikačný token.', 403);
    }
    return strtoupper((string) ($_SERVER['HTTP_X_NODE_ID'] ?? ''));
}

/** Zmeny z prehliadača: JSON alebo vlastná hlavička – bráni CSRF z cudzích stránok. */
function requireBrowserWrite(): void
{
    if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'dt-ui') {
        throw new AppError('Chýba hlavička X-Requested-With.', 400);
    }
}

/** Paralelne načíta /api/status všetkých uzlov pre stavový panel. */
function fetchPeerStatuses(): array
{
    $multi = curl_multi_init();
    $handles = [];
    foreach (peers() as $peer => $url) {
        $handle = curl_init($url . '/api/status');
        curl_setopt_array($handle, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 2,
            CURLOPT_TIMEOUT => 3,
            CURLOPT_HTTPHEADER => ['Accept: application/json'],
        ]);
        curl_multi_add_handle($multi, $handle);
        $handles[$peer] = $handle;
    }
    do {
        $status = curl_multi_exec($multi, $active);
        if ($active) {
            curl_multi_select($multi, 0.2);
        }
    } while ($active && $status === CURLM_OK);

    $result = [];
    foreach ($handles as $peer => $handle) {
        $body = json_decode((string) curl_multi_getcontent($handle), true);
        $code = (int) curl_getinfo($handle, CURLINFO_HTTP_CODE);
        $result[] = $code === 200 && is_array($body)
            ? ['online' => true] + $body
            : ['online' => false, 'node_id' => $peer, 'url' => peers()[$peer], 'error' => curl_error($handle) ?: "HTTP {$code}"];
        curl_multi_remove_handle($multi, $handle);
        curl_close($handle);
    }
    curl_multi_close($multi);
    return $result;
}

$method = $_SERVER['REQUEST_METHOD'];
$path = '/' . trim(substr(parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?: '', strlen('/api')), '/');
$segments = explode('/', trim($path, '/'));

try {
    $db = database();

    switch (true) {
        case $path === '/status' && $method === 'GET':
            respond(200, localStatus($db));

        case $path === '/cluster' && $method === 'GET':
            $self = ['online' => true] + localStatus($db);
            respond(200, ['self' => $self, 'nodes' => array_merge([$self], fetchPeerStatuses())]);

        case $path === '/records' && $method === 'GET':
            respond(200, ['records' => listRecords($db, ($_GET['deleted'] ?? '') === '1')]);

        case $path === '/records' && $method === 'POST':
            requireBrowserWrite();
            respond(201, ['record' => createRecord($db, requestBody())]);

        case $segments[0] === 'records' && count($segments) === 2:
            $id = strtolower($segments[1]);
            if ($method === 'GET') {
                $record = findRecord($db, $id);
                $record === null ? respond(404, ['error' => 'Záznam neexistuje.']) : respond(200, ['record' => $record]);
            }
            if ($method === 'PUT' || $method === 'PATCH') {
                requireBrowserWrite();
                respond(200, ['record' => changeOwnedRecord($db, $id, requestBody())]);
            }
            if ($method === 'DELETE') {
                requireBrowserWrite();
                respond(200, ['record' => changeOwnedRecord($db, $id, null)]);
            }
            break;

        case $path === '/outbox' && $method === 'GET':
            $rows = $db->query(
                'SELECT op_id, peer_node, record_id, op_type, version, attempts, next_attempt_at, last_error, created_at
                 FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT 200'
            )->fetchAll();
            respond(200, ['pending' => $rows]);

        case $path === '/sync' && $method === 'POST':
            requireBrowserWrite();
            $result = syncAll($db);
            respond($result['ok'] ? 200 : 503, $result);

        case $path === '/integrity' && $method === 'GET':
            $broken = verifyStoredChecksums($db);
            respond($broken === [] ? 200 : 500, ['ok' => $broken === [], 'broken' => $broken]);

        // ---- Endpointy medzi uzlami (token) ----
        case $path === '/replicate' && $method === 'POST':
            $fromNode = requirePeerToken();
            $body = requestBody();
            if (($body['from_node'] ?? null) !== $fromNode || !is_array($body['ops'] ?? null)) {
                throw new AppError('Neplatná dávka operácií.', 400);
            }
            $results = [];
            foreach ($body['ops'] as $op) {
                $opId = (string) ($op['op_id'] ?? '');
                try {
                    if (!preg_match('/^[0-9a-f-]{36}$/', $opId) || !in_array($op['op_type'] ?? '', ['CREATE', 'UPDATE', 'DELETE'], true)) {
                        throw new AppError('Neplatná operácia.', 422);
                    }
                    if (($op['record']['origin_node'] ?? null) !== $fromNode) {
                        throw new AppError('Operáciu môže posielať iba vlastník záznamu.', 403);
                    }
                    $status = applyRemoteRecord($db, $op['record'], $fromNode, $opId, $op['op_type']);
                    $results[] = ['op_id' => $opId, 'status' => $status];
                } catch (AppError $error) {
                    logEvent('error', 'operation_rejected', ['op_id' => $opId, 'from' => $fromNode, 'error' => $error->getMessage()]);
                    $results[] = ['op_id' => $opId, 'status' => 'rejected', 'error' => $error->getMessage()];
                }
            }
            respond(200, ['node_id' => nodeId(), 'results' => $results]);

        case $path === '/manifest' && $method === 'GET':
            requirePeerToken();
            respond(200, buildManifest($db));

        case $path === '/export' && $method === 'POST':
            requirePeerToken();
            $ids = array_slice(array_filter((array) (requestBody()['ids'] ?? []), 'is_string'), 0, 500);
            $records = [];
            foreach ($ids as $id) {
                if ($record = findRecord($db, $id)) {
                    $records[] = $record;
                }
            }
            respond(200, ['records' => $records]);
    }

    respond(404, ['error' => "Neznámy endpoint {$method} {$path}."]);
} catch (AppError $error) {
    respond($error->status, ['error' => $error->getMessage()]);
} catch (Throwable $error) {
    logEvent('error', 'api_error', ['path' => $path, 'error' => $error->getMessage()]);
    respond(503, ['error' => 'Služba uzla je dočasne nedostupná.']);
}
