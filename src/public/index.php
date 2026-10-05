<?php
declare(strict_types=1);

require_once __DIR__ . '/../lib/bootstrap.php';

function escape(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$nodeId = nodeId();
$nodeLabel = nodeLabel();
?>
<!doctype html>
<html lang="sk">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Uzol <?= escape($nodeId) ?> | Poruchy kín</title>
    <link rel="stylesheet" href="/assets/app.css">
</head>
<body data-node="<?= escape($nodeId) ?>">
<header>
    <strong>Sieť kín <span>/ distribuovaná evidencia porúch</span></strong>
    <span>Uzol <b><?= escape($nodeId) ?></b> · <?= escape($nodeLabel) ?> · v<?= escape(appVersion()) ?></span>
</header>
<main>
    <section class="panel">
        <div class="panel-head">
            <h2>Stav uzlov</h2>
            <div class="actions">
                <span id="consistency" class="badge">…</span>
                <button id="sync" type="button" class="secondary">Synchronizovať teraz</button>
            </div>
        </div>
        <div id="nodes" class="nodes" aria-live="polite"></div>
    </section>

    <div id="notice" class="notice" role="status" hidden></div>

    <div class="layout">
        <section>
            <h2>Nahlásiť poruchu</h2>
            <form id="create">
                <label for="cislo_saly">Číslo sály</label>
                <input id="cislo_saly" name="cislo_saly" maxlength="32" required>
                <label for="popis">Popis chyby</label>
                <textarea id="popis" name="popis" maxlength="1000" placeholder="Napr. vypálená lampa projektora" required></textarea>
                <button type="submit">Uložiť poruchu</button>
            </form>
            <p class="muted small">Záznam sa uloží lokálne a do outboxu. Worker ho odošle ostatným uzlom; pri výpadku čaká a odošle ho po obnovení spojenia.</p>
        </section>

        <section>
            <div class="panel-head">
                <h2>Poruchy <span class="muted" id="count"></span></h2>
                <label class="inline"><input type="checkbox" id="show-deleted"> zobraziť zmazané (tombstone)</label>
            </div>
            <div class="table-wrap">
                <table>
                    <thead><tr><th>Sála</th><th>Popis</th><th>Stav</th><th>Vlastník</th><th>Verzia</th><th>Upravené (UTC)</th><th>ID / checksum</th><th></th></tr></thead>
                    <tbody id="records"><tr><td colspan="8" class="empty">Načítavam…</td></tr></tbody>
                </table>
            </div>
            <h3>Neodoslané operácie <span class="muted" id="pending-count"></span></h3>
            <div class="table-wrap">
                <table>
                    <thead><tr><th>Operácia</th><th>Cieľ</th><th>Záznam</th><th>Verzia</th><th>Pokusy</th><th>Ďalší pokus</th><th>Chyba</th></tr></thead>
                    <tbody id="outbox"></tbody>
                </table>
            </div>
        </section>
    </div>
</main>

<dialog id="edit-dialog">
    <form id="edit" method="dialog">
        <h2>Upraviť poruchu</h2>
        <input type="hidden" name="record_id">
        <label for="edit-sala">Číslo sály</label>
        <input id="edit-sala" name="cislo_saly" maxlength="32" required>
        <label for="edit-popis">Popis chyby</label>
        <textarea id="edit-popis" name="popis" maxlength="1000" required></textarea>
        <label for="edit-stav">Stav</label>
        <select id="edit-stav" name="stav">
            <option value="nova">nová</option>
            <option value="riesi_sa">rieši sa</option>
            <option value="vyriesena">vyriešená</option>
        </select>
        <div class="dialog-actions">
            <button type="button" class="secondary" data-close>Zrušiť</button>
            <button type="submit">Uložiť</button>
        </div>
    </form>
</dialog>
<script src="/assets/app.js"></script>
</body>
</html>
