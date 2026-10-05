'use strict';

const NODE = document.body.dataset.node;
const STATES = { nova: 'nová', riesi_sa: 'rieši sa', vyriesena: 'vyriešená' };
const $ = (selector) => document.querySelector(selector);

const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const short = (value, length = 8) => (value ? esc(String(value).slice(0, length)) : '–');

async function api(path, options = {}) {
    const init = { method: options.method || 'GET', headers: { Accept: 'application/json' } };
    if (init.method !== 'GET') init.headers['X-Requested-With'] = 'dt-ui';
    if (options.body !== undefined) {
        init.headers['Content-Type'] = 'application/json';
        init.body = JSON.stringify(options.body);
    }
    const response = await fetch('/api' + path, init);
    const data = await response.json().catch(() => ({}));
    if (!response.ok && !options.allowError) throw new Error(data.error || `HTTP ${response.status}`);
    return { status: response.status, data };
}

function notify(message, isError = false) {
    const box = $('#notice');
    box.textContent = message;
    box.classList.toggle('error', isError);
    box.hidden = false;
    clearTimeout(notify.timer);
    notify.timer = setTimeout(() => { box.hidden = true; }, 8000);
}

function renderNodes(cluster) {
    const nodes = cluster.nodes;
    $('#nodes').innerHTML = nodes.map((node) => {
        if (!node.online) {
            return `<article class="node"><h4>${esc(node.node_id)} <span class="badge bad">offline</span></h4>
                <dl><dt>URL</dt><dd>${esc(node.url)}</dd><dt>Chyba</dt><dd>${esc(node.error)}</dd></dl></article>`;
        }
        const peers = (node.peers || []).map((p) =>
            `<span class="badge ${p.reachable ? 'ok' : 'bad'}" title="${esc(p.last_error || '')}">${esc(p.node_id)}${p.pending ? ' · ' + p.pending : ''}</span>`
        ).join(' ');
        return `<article class="node online ${node.node_id === NODE ? 'self' : ''}">
            <h4>${esc(node.node_id)} · ${esc(node.label)} <span class="badge ok">online</span></h4>
            <dl>
                <dt>Záznamy</dt><dd>${node.records.active} aktívnych / ${node.records.deleted} zmazaných</dd>
                <dt>Manifest</dt><dd class="hash">${short(node.manifest_hash, 16)}</dd>
                <dt>Outbox</dt><dd>${node.outbox.pending} čaká · ${node.outbox.sent} odoslaných</dd>
                <dt>Inbox</dt><dd>${node.inbox.received} prijatých · ${node.inbox.duplicates_ignored} duplicít ignorovaných</dd>
                <dt>Worker</dt><dd>${node.worker.alive ? `<span class="badge ok">beží</span> (${node.worker.age_s}s)` : '<span class="badge bad">neodpovedá</span>'}</dd>
                <dt>Vidí uzly</dt><dd>${peers || '–'}</dd>
            </dl></article>`;
    }).join('');

    const online = nodes.filter((n) => n.online);
    const hashes = new Set(online.map((n) => n.manifest_hash));
    const pending = online.reduce((sum, n) => sum + n.outbox.pending, 0);
    const badge = $('#consistency');
    if (online.length < nodes.length) {
        badge.className = 'badge bad';
        badge.textContent = `výpadok: ${nodes.length - online.length} uzol(y) nedostupné`;
    } else if (hashes.size === 1 && pending === 0) {
        badge.className = 'badge ok';
        badge.textContent = 'všetky uzly konzistentné';
    } else {
        badge.className = 'badge warn';
        badge.textContent = `synchronizuje sa (${pending} čaká)`;
    }
}

function renderRecords(records) {
    $('#count').textContent = `(${records.filter((r) => !r.deleted_at).length})`;
    if (!records.length) {
        $('#records').innerHTML = '<tr><td colspan="8" class="empty">Zatiaľ nie sú zaevidované žiadne poruchy.</td></tr>';
        return;
    }
    $('#records').innerHTML = records.map((r) => {
        const own = r.origin_node === NODE && !r.deleted_at;
        const actions = own
            ? `<button class="link" data-edit="${esc(r.id)}">upraviť</button><button class="link danger" data-delete="${esc(r.id)}">zmazať</button>`
            : (r.deleted_at ? '<span class="muted">tombstone</span>' : '<span class="muted" title="Meniť môže iba vlastník">len čítanie</span>');
        return `<tr class="${r.deleted_at ? 'deleted' : ''}">
            <td>${esc(r.cislo_saly)}</td><td>${esc(r.popis)}</td><td class="nowrap">${esc(STATES[r.stav] || r.stav)}</td>
            <td>${esc(r.origin_node)}</td><td>v${r.version}</td><td class="nowrap">${esc(r.updated_at)}</td>
            <td class="hash" title="${esc(r.id)}\n${esc(r.checksum)}">${short(r.id)} / ${short(r.checksum)}</td>
            <td class="nowrap">${actions}</td></tr>`;
    }).join('');
    renderRecords.cache = Object.fromEntries(records.map((r) => [r.id, r]));
}

function renderOutbox(rows) {
    $('#pending-count').textContent = `(${rows.length})`;
    $('#outbox').innerHTML = rows.length
        ? rows.map((o) => `<tr><td>${esc(o.op_type)}</td><td>${esc(o.peer_node)}</td><td class="hash">${short(o.record_id)}</td>
            <td>v${o.version}</td><td>${o.attempts}</td><td class="nowrap">${esc(o.next_attempt_at)}</td><td>${esc(o.last_error || '')}</td></tr>`).join('')
        : '<tr><td colspan="7" class="empty">Všetko odoslané.</td></tr>';
}

async function refresh() {
    try {
        const deleted = $('#show-deleted').checked ? '?deleted=1' : '';
        const [cluster, records, outbox] = await Promise.all([api('/cluster'), api('/records' + deleted), api('/outbox')]);
        renderNodes(cluster.data);
        renderRecords(records.data.records);
        renderOutbox(outbox.data.pending);
    } catch (error) {
        notify('Uzol neodpovedá: ' + error.message, true);
    }
}

$('#create').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        await api('/records', { method: 'POST', body: { cislo_saly: form.cislo_saly.value, popis: form.popis.value } });
        form.reset();
        notify('Porucha uložená lokálne a zaradená na replikáciu.');
        refresh();
    } catch (error) { notify(error.message, true); }
});

$('#sync').addEventListener('click', async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    try {
        const { data } = await api('/sync', { method: 'POST', allowError: true });
        const detail = Object.entries(data.peers || {}).map(([peer, r]) =>
            r.ok ? `${peer}: OK (odoslané ${r.pushed}, prijaté ${r.pulled})` : `${peer}: ZLYHALO – ${r.error}`).join(' | ');
        notify((data.ok ? 'Synchronizácia úspešná. ' : 'Synchronizácia bezpečne zlyhala, operácie zostávajú v outboxe. ') + detail, !data.ok);
    } catch (error) { notify(error.message, true); }
    button.disabled = false;
    refresh();
});

$('#records').addEventListener('click', async (event) => {
    const editId = event.target.dataset.edit;
    const deleteId = event.target.dataset.delete;
    if (editId) {
        const record = renderRecords.cache[editId];
        const form = $('#edit');
        form.record_id.value = record.id;
        form.cislo_saly.value = record.cislo_saly;
        form.popis.value = record.popis;
        form.stav.value = record.stav;
        $('#edit-dialog').showModal();
    }
    if (deleteId && confirm('Zmazať poruchu? Na všetky uzly sa replikuje tombstone.')) {
        try {
            await api('/records/' + deleteId, { method: 'DELETE' });
            notify('Porucha zmazaná (tombstone).');
            refresh();
        } catch (error) { notify(error.message, true); }
    }
});

$('#edit').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    try {
        await api('/records/' + form.record_id.value, { method: 'PUT', body: { cislo_saly: form.cislo_saly.value, popis: form.popis.value, stav: form.stav.value } });
        $('#edit-dialog').close();
        notify('Porucha upravená, nová verzia sa replikuje.');
        refresh();
    } catch (error) { notify(error.message, true); }
});

document.querySelector('[data-close]').addEventListener('click', () => $('#edit-dialog').close());
$('#show-deleted').addEventListener('change', refresh);

refresh();
setInterval(refresh, 3000);
