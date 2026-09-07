'use strict';
'require dom';
'require fs';
'require form';
'require poll';
'require uci';
'require ui';
'require view';
'require view.zapret.tools as tools';

/*
 * Win Sync - LuCI view for Flowseal strategies synchronization and testing.
 * Backend scripts (provided by the zapret package):
 *   /opt/zapret/fdy-sync.sh   --check | (none) | --set-cron 'HH:MM' | --del-cron
 *   /opt/zapret/fdy-test.sh   (none) | --apply <name>
 * State files:
 *   /opt/zapret/fdy/logs/state.json
 *   /opt/zapret/fdy/results/last.json
 *   /opt/zapret/fdy/strategies/list.txt
 *   /opt/zapret/fdy/logs/sync.log | /opt/zapret/fdy/logs/test.log
 */

const btn_style_neutral  = 'btn';
const btn_style_action   = 'btn cbi-button-action';
const btn_style_positive = 'btn cbi-button-save important';
const btn_style_warning  = 'btn cbi-button-negative';

const fdy_dir          = tools.appDir + '/fdy';
const fn_fdy_sync_sh   = tools.appDir + '/fdy-sync.sh';
const fn_fdy_test_sh   = tools.appDir + '/fdy-test.sh';

const fdy_state_fn     = fdy_dir + '/logs/state.json';
const fdy_results_fn   = fdy_dir + '/results/last.json';
const fdy_stratlist_fn = fdy_dir + '/strategies/list.txt';
const fdy_synclog_fn   = fdy_dir + '/logs/sync.log';
const fdy_testlog_fn   = fdy_dir + '/logs/test.log';

const fdy_check_log    = '/tmp/fdy_check.log';
const fdy_sync_log     = '/tmp/fdy_sync_live.log';
const fdy_test_log     = '/tmp/fdy_test_live.log';

const skey_winsync_test = tools.appName + '-winsync-testing';

return view.extend({
    POLL: new tools.POLLER({ interval: 5000 }),  // 5 sec

    /* ---------------------------------------------------------------- */
    /* helpers                                                          */
    /* ---------------------------------------------------------------- */

    jsonParseSafe: function(txt) {
        try {
            return JSON.parse(txt);
        } catch (e) {
            return null;
        }
    },

    readFile: function(fn) {
        return L.resolveDefault(fs.read(fn), null).then(data => {
            return (data && data.length > 0) ? data : null;
        }).catch(() => { return null; });
    },

    readJsonFile: function(fn) {
        return this.readFile(fn).then(data => {
            return (data) ? this.jsonParseSafe(data) : null;
        });
    },

    tailFile: function(fn, lines = 60) {
        return fs.exec('/bin/busybox', [ 'tail', '-n', '' + lines, fn ]).then(res => {
            return (res.code == 0 && res.stdout) ? res.stdout : '';
        }).catch(() => { return ''; });
    },

    /* ---------------------------------------------------------------- */
    /* status                                                           */
    /* ---------------------------------------------------------------- */

    getStatusData: function() {
        return tools.promiseAllDict({
            state    : this.readJsonFile(fdy_state_fn),
            results  : this.readJsonFile(fdy_results_fn),
            stratlist: this.readFile(fdy_stratlist_fn),
            live_head: fs.exec('/bin/busybox', [ 'tail', '-n', '1', fdy_test_log ]),
        }).catch(e => {
            console.warn('winsync: getStatusData: ' + e.message);
            return null;
        });
    },

    isTestEndingLine: function(line) {
        return (line && line.match(/^END\s+rc=/)) ? true : false;
    },

    isTestRunning: function() {
        /* true when the page has started a test in this browser session */
        return (localStorage.getItem(skey_winsync_test) == '1') ? true : false;
    },

    setTestRunning: function(flag) {
        if (flag) {
            localStorage.setItem(skey_winsync_test, '1');
        } else {
            localStorage.removeItem(skey_winsync_test);
        }
    },

    setStatus: function(data) {
        let elem = document.getElementById('winsync_status');
        if (!elem) {
            return;
        }
        if (!data) {
            elem.innerHTML = tools.infoLabelStopped;
            return;
        }
        let state = (data.state && typeof(data.state) == 'object') ? data.state : null;
        let results = (data.results && typeof(data.results) == 'object') ? data.results : null;

        let td_name_width = 40;
        let td_name_style = `style="width: ${td_name_width}%; min-width:${td_name_width}%; max-width:${td_name_width}%;"`;

        let ver = (state?.version) ? '' + state.version : _('unknown');
        let synced_at = (state?.synced_at) ? '' + state.synced_at : _('never');
        let sync_status = (state?.status) ? '' + state.status : 'unknown';
        if (state?.error) {
            sync_status += ' (' + state.error + ')';
        }
        let sync_label = {
            'ok'    : tools.infoLabelRunning,
            'sync'  : tools.infoLabelUpdating,
            'update': tools.infoLabelUpdating,
            'error' : tools.infoLabelError,
        }[sync_status] || tools.infoLabelStopped;

        let last_check = (state?.last_check) ? '' + state.last_check : _('never');

        let best = (results?.best) ? '' + results.best : _('unknown');
        let best_score = (results?.best_score !== undefined && results?.best_score !== null)
            ? '' + results.best_score : '-';
        let finished = (results?.finished) ? '' + results.finished : _('never');

        let live_line = (data.live_head?.stdout) ? data.live_head.stdout.trim() : '';
        let testing = this.isTestRunning() && !this.isTestEndingLine(live_line);
        let test_label = testing ? tools.infoLabelUpdating : tools.infoLabelStopped;

        elem.innerHTML = `
            <table class="table">
                <tr class="tr">
                    <td class="td left" ${td_name_style}>
                        ${_('Flowseal data version')}:
                    </td>
                    <td class="td left">
                        ${ver}
                    </td>
                </tr>
                <tr class="tr">
                    <td class="td left" ${td_name_style}>
                        ${_('Last sync')}:
                    </td>
                    <td class="td left">
                        ${synced_at} &nbsp; ${sync_label}
                    </td>
                </tr>
                <tr class="tr">
                    <td class="td left" ${td_name_style}>
                        ${_('Last update check')}:
                    </td>
                    <td class="td left">
                        ${last_check}
                    </td>
                </tr>
                <tr class="tr">
                    <td class="td left" ${td_name_style}>
                        ${_('Best strategy')}:
                    </td>
                    <td class="td left">
                        ${best} &nbsp; [score: ${best_score}]
                    </td>
                </tr>
                <tr class="tr">
                    <td class="td left" ${td_name_style}>
                        ${_('Last test finished')}:
                    </td>
                    <td class="td left">
                        ${finished} &nbsp; ${test_label}
                    </td>
                </tr>
            </table>`;
    },

    statusPoll: function() {
        if (tools.isModalActive()) {
            return;
        }
        /* auto-stop the poller when the test is over */
        return fs.exec('/bin/busybox', [ 'tail', '-n', '1', fdy_test_log ]).then(res => {
            let lastline = (res.stdout) ? res.stdout.trim() : '';
            if (this.isTestRunning() && this.isTestEndingLine(lastline)) {
                this.setTestRunning(false);
                this.POLL.stop();
                this.refreshAll();
            }
            return this.getStatusData().then(data => this.setStatus(data));
        }).catch(() => { });
    },

    refreshAll: function() {
        return this.getStatusData().then(data => {
            this.setStatus(data);
            this.renderStrategies(data);
        });
    },

    /* ---------------------------------------------------------------- */
    /* strategies table                                                 */
    /* ---------------------------------------------------------------- */

    renderStrategies: function(data) {
        let container = document.getElementById('winsync_strats');
        if (!container) {
            return;
        }
        let names = [ ];
        if (data && data.stratlist) {
            names = tools.getWordsArray(data.stratlist);
        }
        let results = (data && data.results && typeof(data.results) == 'object') ? data.results : null;
        let resmap = { };
        if (results && Array.isArray(results.strategies)) {
            for (let i = 0; i < results.strategies.length; i++) {
                let st = results.strategies[i];
                if (st && st.name) {
                    resmap[st.name] = st;
                }
            }
        }
        let best = (results?.best) ? '' + results.best : null;

        if (names.length == 0) {
            dom.content(container, [
                E('p', { 'class': 'cbi-section-descr' },
                    _('Strategy list is empty. Run sync first.'))
            ]);
            return;
        }

        let rows = [ ];
        names.forEach(name => {
            let st = resmap[name] || null;
            let score = (st && st.score !== undefined && st.score !== null) ? '' + st.score : '-';
            let flags = [ ];
            if (st) {
                if (st.ok) {
                    flags.push(E('span', { 'class': 'label-status running' }, 'OK'));
                } else {
                    flags.push(E('span', { 'class': 'label-status stopped' }, 'FAIL'));
                }
                if (st.err) {
                    flags.push(' ' + st.err);
                }
                if (st.unsup) {
                    flags.push(' ' + _('unsupported'));
                }
                if (st.ping_ok !== undefined && st.ping_ok !== null) {
                    flags.push(' ping: ' + (st.ping_ok ? 'ok' : 'fail'));
                }
            } else {
                flags.push(E('em', {}, _('no results yet')));
            }
            let row_class = 'tr';
            let row_style = '';
            if (best && name == best) {
                row_class = 'tr';
                row_style = 'style="background-color: rgba(46,162,86,0.15); font-weight: bold;"';
            }
            let apply_btn = E('button', {
                'class': 'btn cbi-button-action btn_apply_strat',
                'data-strat': name,
            }, _('Apply'));
            apply_btn.onclick = ui.createHandlerFn(this, (ev) => {
                return this.confirmApplyStrategy(name, ev);
            });
            rows.push(E('tr', { 'class': row_class, 'style': row_style }, [
                E('td', { 'class': 'td left' }, [ name ]),
                E('td', { 'class': 'td left' }, [ score ]),
                E('td', { 'class': 'td left' }, [ flags ]),
                E('td', { 'class': 'td left' }, [ (best && name == best) ? E('strong', {}, _('best')) : '' ]),
                E('td', { 'class': 'td left' }, [ apply_btn ]),
            ]));
        });

        let table = E('table', { 'class': 'table' }, [
            E('tr', { 'class': 'tr table-titles' }, [
                E('th', { 'class': 'th left' }, _('Strategy')),
                E('th', { 'class': 'th left' }, _('Score')),
                E('th', { 'class': 'th left' }, _('Status')),
                E('th', { 'class': 'th left' }, ''),
                E('th', { 'class': 'th left' }, ''),
            ])
        ].concat(rows));

        dom.content(container, [ table ]);
    },

    /* ---------------------------------------------------------------- */
    /* actions                                                          */
    /* ---------------------------------------------------------------- */

    actionCheckUpdates: function(ev) {
        this.appendLog(_('Checking for Flowseal updates...'));
        return tools.execAndRead({
            cmd: [ fn_fdy_sync_sh, '--check' ],
            log: fdy_check_log,
            logArea: this.logArea,
            callback: (rc, txt = '') => {
                if (rc == 0 && txt) {
                    let m = txt.match(/^RESULT:\s*\(([^)]+)\)\s+(.+)$/m);
                    let v = txt.match(/^VERSION=(.+)$/m);
                    let ver_tag = v ? v[1].trim() : (m ? m[2].trim() : null);
                    this.appendLog('=========================================================');
                    if (m) {
                        let state_map = { L: _('new release available'), E: _('up to date'), G: _('local version is newer') };
                        this.appendLog(_('Check result') + ': ' + (state_map[m[1]] || m[1]) + (ver_tag ? ' [' + ver_tag + ']' : ''));
                    } else {
                        this.appendLog(_('Check result') + ': ' + _('unknown'));
                    }
                    this.refreshAll();
                    return;
                }
                if (rc >= 500) {
                    this.appendLog(txt ? (txt.startsWith('ERROR') ? txt : 'ERROR: ' + txt) : 'ERROR: check failed');
                } else {
                    this.appendLog('ERROR: Process finished with retcode = ' + rc);
                }
                this.appendLog('=========================================================');
            },
            ctx: this,
        });
    },

    actionSyncNow: function(ev) {
        this.appendLog(_('Syncing with Flowseal releases...'));
        return tools.execAndRead({
            cmd: [ fn_fdy_sync_sh, '--force' ],
            log: fdy_sync_log,
            logArea: this.logArea,
            callback: (rc, txt = '') => {
                if (rc == 0) {
                    this.appendLog(_('Sync finished.'));
                    this.appendLog('=========================================================');
                    this.refreshAll();
                    return;
                }
                if (rc >= 500) {
                    this.appendLog(txt ? (txt.startsWith('ERROR') ? txt : 'ERROR: ' + txt) : 'ERROR: sync failed');
                } else {
                    this.appendLog('ERROR: Process finished with retcode = ' + rc);
                }
                this.appendLog('=========================================================');
            },
            ctx: this,
        });
    },

    actionRunTests: function() {
        this.setTestRunning(true);
        this.appendLog(_('Running strategies tests (this may take a while)...'));
        return tools.execAndRead({
            cmd: [ fn_fdy_test_sh ],
            log: fdy_test_log,
            logArea: this.logArea,
            callback: (rc, txt = '') => {
                this.setTestRunning(false);
                this.POLL.stop();
                if (rc == 0) {
                    this.appendLog(_('Tests finished.'));
                } else {
                    this.appendLog(_('Tests finished with errors') + ' (rc = ' + rc + ')');
                }
                this.appendLog('=========================================================');
                this.refreshAll();
            },
            ctx: this,
        });
    },

    actionApplyStrategy: function(name) {
        this.appendLog(_('Applying strategy') + ': ' + name + ' ...');
        return tools.execAndRead({
            cmd: [ fn_fdy_test_sh, '--apply', name ],
            log: fdy_test_log,
            logArea: this.logArea,
            callback: (rc, txt = '') => {
                if (rc == 0) {
                    this.appendLog(_('Strategy applied') + ': ' + name);
                } else {
                    this.appendLog(_('Failed to apply strategy') + ' "' + name + '" (rc = ' + rc + ')');
                }
                this.appendLog('=========================================================');
                this.refreshAll();
            },
            ctx: this,
        });
    },

    /* ---------------------------------------------------------------- */
    /* dialogs                                                          */
    /* ---------------------------------------------------------------- */

    appendLog: function(msg, end = '\n') {
        if (!this.logArea) {
            return;
        }
        this.logArea.value += msg + end;
        this.logArea.scrollTop = this.logArea.scrollHeight;
    },

    confirmRunTests: function(ev) {
        if (tools.checkUnsavedChanges()) {
            ui.addNotification(null, E('p', _('You have unapplied changes')));
            return;
        }
        let warn = E('div', { 'class': 'cbi-section' }, [
            E('p', {}, _('During the test the Internet connection may be interrupted.')),
            E('p', {}, _('The test may take up to 10 minutes. Continue?')),
        ]);
        let btn_cancel = E('button', {
            'class': btn_style_warning,
            'click': ui.hideModal,
        }, _('Cancel'));
        let btn_ok = E('button', {
            'class': btn_style_positive,
            'click': ui.createHandlerFn(this, () => {
                ui.hideModal();
                return this.actionRunTests();
            }),
        }, _('Continue'));
        ui.showModal(_('Run strategies test'), [
            warn,
            E('div', { 'style': 'display:flex; justify-content:space-between; align-items:center; margin-top:1px;' }, [
                E('div', { 'class': 'left' }, [ btn_ok ]),
                E('div', { 'class': 'right' }, [ btn_cancel ]),
            ]),
        ]);
    },

    confirmApplyStrategy: function(name, ev) {
        if (tools.checkUnsavedChanges()) {
            ui.addNotification(null, E('p', _('You have unapplied changes')));
            return;
        }
        let btn_cancel = E('button', {
            'class': btn_style_warning,
            'click': ui.hideModal,
        }, _('Cancel'));
        let btn_ok = E('button', {
            'class': btn_style_positive,
            'click': ui.createHandlerFn(this, () => {
                ui.hideModal();
                return this.actionApplyStrategy(name);
            }),
        }, _('Apply'));
        ui.showModal(_('Apply strategy'), [
            E('div', { 'class': 'cbi-section' }, [
                E('p', {}, _('Apply strategy "%s" now?').format(name)),
                E('p', {}, _('The Internet connection may be interrupted for a short time.')),
            ]),
            E('div', { 'style': 'display:flex; justify-content:space-between; align-items:center; margin-top:1px;' }, [
                E('div', { 'class': 'left' }, [ btn_ok ]),
                E('div', { 'class': 'right' }, [ btn_cancel ]),
            ]),
        ]);
    },

    /* ---------------------------------------------------------------- */
    /* log                                                              */
    /* ---------------------------------------------------------------- */

    refreshLogArea: function(mode) {
        let fn = (mode == 'sync') ? fdy_synclog_fn : fdy_testlog_fn;
        return this.tailFile(fn, 80).then(data => {
            if (this.logArea) {
                this.logArea.value = data || '';
                this.logArea.scrollTop = this.logArea.scrollHeight;
            }
        });
    },

    /* ---------------------------------------------------------------- */
    /* uci sections bootstrap                                           */
    /* ---------------------------------------------------------------- */
    /* fdy settings live in the dedicated uci config 'fdy':
     *   fdy.sync    (type sync)    : enabled, time, mirror, autotest, restart_after
     *   fdy.test    (type test)    : curl_timeout, start_wait, max_parallel, targets
     *   fdy.general (type general) : gamefilter
     * The backend scripts (fdy-lib.sh) create these sections with defaults
     * on first run; the view also stages them client-side so that the form
     * is rendered even before the first sync.                        */

    ensureFdySections: function() {
        const sec_defs = [
            { sid: 'sync'   , type: 'sync'   },
            { sid: 'test'   , type: 'test'   },
            { sid: 'general', type: 'general'},
        ];
        sec_defs.forEach(def => {
            if (uci.get('fdy', def.sid) == null) {
                uci.add('fdy', def.type, def.sid);
            }
        });
    },

    /* ---------------------------------------------------------------- */
    /* save hook                                                        */
    /* ---------------------------------------------------------------- */

    updateCronEntry: function() {
        let enabled = (uci.get('fdy', 'sync', 'enabled') == '1');
        let time = uci.get('fdy', 'sync', 'time') || '';
        return fs.exec(fn_fdy_sync_sh, [ enabled ? '--set-cron' : '--del-cron' ].concat(enabled ? [ time.trim() ] : [ ])).then(res => {
            if (res.code != 0) {
                ui.addNotification(null, E('p', _('Failed to update the sync schedule') + ' (rc = ' + res.code + ')'));
            }
        }).catch(e => {
            ui.addNotification(null, E('p', _('Failed to update the sync schedule') + ': ' + e.message));
        });
    },

    handleSaveApply: function(ev, mode) {
        return this.handleSave(ev).then(() => {
            let apply_exec = tools.checkUnsavedChanges();
            if (apply_exec) {
                ui.changes.apply(mode == '0');
                /* re-apply the cron schedule right after the uci apply */
                let cron_done = false;
                let run_cron = () => {
                    if (cron_done) {
                        return;
                    }
                    cron_done = true;
                    this.updateCronEntry();
                };
                document.addEventListener('uci-applied', run_cron, { once: true });
                setTimeout(run_cron, 6000);  /* fallback if the event never fires */
                return;
            }
            return this.updateCronEntry();
        });
    },

    /* ---------------------------------------------------------------- */
    /* view                                                             */
    /* ---------------------------------------------------------------- */

    load: function() {
        return Promise.all([
            tools.baseLoad(this, (data) => {
                tools.load_feat_env();
                return data;
            }),
            L.resolveDefault(uci.load('fdy'), null).then(() => {
                this.ensureFdySections();
            }),
            this.getStatusData(),
        ]).then(([ base_data, uci_data, status_data ]) => {
            return status_data;
        });
    },

    render: function(status_data) {
        let m, s, o;

        /* ---------------------------------------------------------- */
        /* status card + buttons                                      */
        /* ---------------------------------------------------------- */

        let status_card = E('div', {
            'id'   : 'winsync_status',
            'name' : 'winsync_status',
            'class': 'cbi-section-node',
        });

        let layout = E('div', { 'class': 'cbi-section-node' });

        let layout_append = function(title, descr, elems) {
            descr = (descr) ? E('div', { 'class': 'cbi-value-description' }, descr) : '';
            let elem_list = [ ];
            for (let i = 0; i < elems.length; i++) {
                elem_list.push(elems[i]);
                elem_list.push(' ');
            }
            layout.append(
                E('div', { 'class': 'cbi-value' }, [
                    E('label', { 'class': 'cbi-value-title' }, title),
                    E('div', { 'class': 'cbi-value-field' }, [
                        E('div', {}, elem_list),
                        descr,
                    ]),
                ])
            );
        };

        let create_btn = function(name, _class, locname) {
            return E('button', {
                'id'   : name,
                'name' : name,
                'class': _class,
            }, locname);
        };

        let btn_check = create_btn('btn_fdy_check', btn_style_action, _('Check updates'));
        btn_check.onclick = ui.createHandlerFn(this, this.actionCheckUpdates);

        let btn_sync = create_btn('btn_fdy_sync', btn_style_action, _('Sync now'));
        btn_sync.onclick = ui.createHandlerFn(this, this.actionSyncNow);

        let btn_test = create_btn('btn_fdy_test', btn_style_positive, _('Run tests'));
        btn_test.onclick = ui.createHandlerFn(this, this.confirmRunTests);

        layout_append(_('Flowseal sync control'), null, [ btn_check, btn_sync ]);
        layout_append(_('Strategies test'), _('The test runs all strategies and may interrupt the Internet connection.'), [ btn_test ]);

        this.setStatus(status_data);
        this.renderStrategies(status_data);

        /* ---------------------------------------------------------- */
        /* settings form                                              */
        /* ---------------------------------------------------------- */

        m = new form.Map('fdy', _('Win Sync') + ' - ' + _('Settings'));

        s = m.section(form.NamedSection, 'sync', 'sync');
        s.anonymous = false;
        s.addremove = false;
        s.title = _('Sync schedule');

        o = s.option(form.Flag, 'enabled', _('Enable scheduled sync'));
        o.rmempty = false;
        o.default = '0';

        o = s.option(form.Value, 'time', _('Sync time'));
        o.placeholder = '04:30';
        o.rmempty = false;
        o.datatype = 'string';
        o.depends('enabled', '1');
        o.validate = function(section_id, value) {
            if (!value || value.length == 0) {
                return true;
            }
            if (!value.match(/^\d{1,2}:\d{2}$/)) {
                return _('Expected format: HH:MM');
            }
            let parts = value.split(':');
            let hh = parseInt(parts[0], 10);
            let mm = parseInt(parts[1], 10);
            if (isNaN(hh) || isNaN(mm) || hh < 0 || hh > 23 || mm < 0 || mm > 59) {
                return _('Expected format: HH:MM');
            }
            return true;
        };

        o = s.option(form.Value, 'mirror', _('Mirror URL'));
        o.placeholder = 'https://github.com/Flowseal/zapret-discord-youtube';
        o.rmempty = true;
        o.datatype = 'string';

        o = s.option(form.Flag, 'autotest', _('Run tests after sync'));
        o.rmempty = false;
        o.default = '0';

        o = s.option(form.Flag, 'restart_after', _('Restart service after sync'));
        o.rmempty = false;
        o.default = '0';

        s = m.section(form.NamedSection, 'test', 'test');
        s.anonymous = false;
        s.addremove = false;
        s.title = _('Test settings');

        o = s.option(form.Value, 'curl_timeout', _('curl timeout (seconds)'));
        o.placeholder = '5';
        o.rmempty = true;
        o.datatype = 'uinteger';

        o = s.option(form.Value, 'start_wait', _('Start wait time (seconds)'));
        o.placeholder = '3';
        o.rmempty = true;
        o.datatype = 'uinteger';

        o = s.option(form.Value, 'max_parallel', _('Max parallel tests'));
        o.placeholder = '1';
        o.rmempty = true;
        o.datatype = 'uinteger';

        o = s.option(form.Value, 'targets', _('Targets file path'));
        o.placeholder = '/opt/zapret/fdy/targets.txt';
        o.rmempty = true;
        o.datatype = 'string';

        s = m.section(form.NamedSection, 'general', 'general');
        s.anonymous = false;
        s.addremove = false;
        s.title = _('General');

        o = s.option(form.ListValue, 'gamefilter', _('Game filter'));
        o.value('off', _('off'));
        o.value('all', _('all games'));
        o.value('tcp', _('TCP only'));
        o.value('udp', _('UDP only'));
        o.rmempty = false;
        o.default = 'off';

        /* ---------------------------------------------------------- */
        /* strategies + log                                           */
        /* ---------------------------------------------------------- */

        let strat_container = E('div', {
            'id'   : 'winsync_strats',
            'name' : 'winsync_strats',
            'class': 'cbi-section-node',
        });

        this.logArea = E('textarea', {
            'id': 'winsync_log',
            'readonly': true,
            'style': 'width:100% !important; font-family: monospace;',
            'rows': 16,
            'wrap': 'off',
        });

        let btn_log_test = create_btn('btn_fdy_log_test', btn_style_neutral, _('Read test log'));
        btn_log_test.onclick = ui.createHandlerFn(this, () => { return this.refreshLogArea('test'); });

        let btn_log_sync = create_btn('btn_fdy_log_sync', btn_style_neutral, _('Read sync log'));
        btn_log_sync.onclick = ui.createHandlerFn(this, () => { return this.refreshLogArea('sync'); });

        let btn_refresh = create_btn('btn_fdy_refresh', btn_style_action, _('Refresh'));
        btn_refresh.onclick = ui.createHandlerFn(this, () => {
            return this.refreshLogArea('test').then(() => this.refreshAll());
        });

        /* start live-test poller if a test is running */
        if (this.isTestRunning()) {
            this.POLL.init(L.bind(this.statusPoll, this), 5000);  // 5 sec
            this.POLL.start(1000);
        }

        let map_promise = m.render();
        map_promise.then(node => node.classList.add('fade-in'));

        return Promise.all([ map_promise ]).then(([ map_node ]) => {
            return E([
                E('h2', { 'class': 'fade-in' }, tools.AppName + ' - ' + _('Win Sync')),
                E('div', { 'class': 'cbi-section-descr fade-in' },
                    _('Synchronization with Flowseal zapret-discord-youtube releases and strategies testing.')),
                E('div', { 'class': 'cbi-section fade-in' }, [
                    E('h3', {}, _('Status')),
                    status_card,
                ]),
                E('div', { 'class': 'cbi-section fade-in' }, [
                    layout,
                ]),
                map_node,
                E('div', { 'class': 'cbi-section fade-in' }, [
                    E('h3', {}, _('Strategies')),
                    strat_container,
                ]),
                E('div', { 'class': 'cbi-section fade-in' }, [
                    E('h3', {}, _('Log')),
                    this.logArea,
                    E('div', { 'style': 'margin-top:6px;' }, [
                        btn_log_test, ' ', btn_log_sync, ' ', btn_refresh,
                    ]),
                ]),
            ]);
        });
    },
});
