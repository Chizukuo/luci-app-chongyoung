'use strict';
'require view';
'require form';
'require ui';
'require fs';
'require poll';
'require rpc';

var callInitAction = rpc.declare({
	object: 'luci',
	method: 'setInitAction',
	params: [ 'name', 'action' ],
	expect: { result: false }
});

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('chongyoung', _('ChongYoung Network'), _('Configuration for ChongYoung Campus Network Auto Login'));

		s = m.section(form.TypedSection, 'global', _('Status'));
		s.anonymous = true;
		
		o = s.option(form.DummyValue, '_status', _('Current Status'));
		o.rawhtml = true;
		o.default = '<em>' + _('Collecting data...') + '</em>';
		o.cfgvalue = function(section_id) {
			return fs.read('/tmp/chongyoung_status').then(function(status) {
				status = status ? status.trim() : _('Not Running');
				var color = 'green';
				if (status.indexOf('重连') !== -1 || status.indexOf('失败') !== -1) {
					color = 'red';
				} else if (status.indexOf('休眠') !== -1) {
					color = 'orange';
				}
				return '<span style="color:' + color + '; font-weight:bold">' + status + '</span>';
			}).catch(function() {
				return '<span style="color:grey">' + _('Not Running') + '</span>';
			});
		};
		
		o = s.option(form.Button, '_restart', _('Action'));
		o.inputtitle = _('Restart Service');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callInitAction('chongyoung', 'restart').then(function(result) {
				if (result) {
					ui.addNotification(null, E('p', _('Service restarted successfully. Please wait for status update.')), 'info');
				} else {
					ui.addNotification(null, E('p', _('Failed to restart service.')), 'error');
				}
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Failed to restart service: ') + e.message), 'error');
			});
		};
		
		poll.add(function() {
			return fs.read('/tmp/chongyoung_status').then(function(status) {
				var view = document.getElementById('cbi-chongyoung-global-_status');
				if (view) {
					status = status ? status.trim() : _('Not Running');
					var color = 'green';
					if (status.indexOf('重连') !== -1 || status.indexOf('失败') !== -1) {
						color = 'red';
					} else if (status.indexOf('休眠') !== -1) {
						color = 'orange';
					}
					view.innerHTML = '<div class="cbi-value-field"><span style="color:' + color + '; font-weight:bold">' + status + '</span></div>';
				}
			}).catch(function() {
				// Ignore errors to keep polling alive
			});
		});

		s = m.section(form.TypedSection, 'global', _('General Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('Phone Number'));
		o.rmempty = false;

		o = s.option(form.Value, 'password_seed', _('Password Seed'), _('Enter your 6-digit original password. If set, the daily password list below will be ignored.'));
		o.rmempty = true;
		o.datatype = 'string';
		o.validate = function(section_id, value) {
			if (value && value.length !== 6) {
				return _('Password seed must be 6 characters long');
			}
			return true;
		};

		s = m.section(form.TypedSection, 'global', _('Scheduled Pause'), _('Pause the service during specific hours (e.g., when the school network is offline).'));
		s.anonymous = true;

		o = s.option(form.Flag, 'pause_enabled', _('Enable Schedule'));
		o.rmempty = false;

		o = s.option(form.Value, 'pause_start', _('Start Time'), _('Format: HH:MM (24-hour clock)'));
		o.placeholder = '23:30';
		o.depends('pause_enabled', '1');
		o.validate = function(section_id, value) {
			if (!value) return true;
			if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(value)) return _('Invalid time format. Use HH:MM');
			return true;
		};

		o = s.option(form.Value, 'pause_end', _('End Time'), _('Format: HH:MM (24-hour clock)'));
		o.placeholder = '06:30';
		o.depends('pause_enabled', '1');
		o.validate = function(section_id, value) {
			if (!value) return true;
			if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(value)) return _('Invalid time format. Use HH:MM');
			return true;
		};

		o = s.option(form.Flag, 'pause_disconnect_wan', _('Disconnect WAN'), _('Disconnect the WAN interface during the pause period. This helps devices detect network loss faster and switch to mobile data.'));
		o.depends('pause_enabled', '1');

		s = m.section(form.TypedSection, 'passwords', _('Daily Passwords'), _('Paste the 31 generated passwords here. One per line. (Ignored if Password Seed is set)'));
		s.anonymous = true;
		s.collapsible = true;

		o = s.option(form.TextValue, 'password_list', _('Password List'));
		o.rows = 10;
		o.wrap = 'off';
		o.validate = function(section_id, value) {
			if (!value) return true;
			var lines = value.trim().split(/\r?\n/);
			if (lines.length !== 31) {
				return _('Warning: You should provide exactly 31 passwords. Currently: ') + lines.length;
			}
			return true;
		};

		s = m.section(form.TypedSection, 'global', _('Advanced Settings'), _('System parameters from edition.ini') + '<br /><span style="color:red; font-weight:bold">' + _('WARNING: Do not modify unless you know what you are doing!') + '</span>');
		s.anonymous = true;
		s.collapsible = true;
		s.collapsed = true;

		o = s.option(form.Value, 'check_interval', _('Detection Interval'), _('Time in seconds between network checks (Default: 30)'));
		o.datatype = 'uinteger';
		o.placeholder = '30';

		o = s.option(form.Value, 'connect_timeout', _('Connection Timeout'), _('Max time in seconds to connect to server (Default: 5)'));
		o.datatype = 'uinteger';
		o.placeholder = '5';

		o = s.option(form.Value, 'total_timeout', _('Total Timeout'), _('Max time in seconds for the whole operation (Default: 10)'));
		o.datatype = 'uinteger';
		o.placeholder = '10';

		o = s.option(form.Value, 'system', _('System Agent'));
		o = s.option(form.Value, 'prefix', _('Prefix'));
		
		var attrs = ['AidcAuthAttr3', 'AidcAuthAttr4', 'AidcAuthAttr5', 'AidcAuthAttr6', 'AidcAuthAttr8', 'AidcAuthAttr15', 'AidcAuthAttr22', 'AidcAuthAttr23'];
		attrs.forEach(function(attr) {
			o = s.option(form.Value, attr, attr);
		});

		return m.render().then(function(nodes) {
			var footer = E('div', { 'class': 'cbi-section', 'style': 'text-align: center; margin-top: 20px; color: #888;' }, [
				E('span', {}, _('Project hosted on ')),
				E('a', { 'href': 'https://github.com/Chizukuo/luci-app-chongyoung', 'target': '_blank', 'style': 'color: #0069b4; text-decoration: none; font-weight: bold;' }, 'GitHub'),
				E('span', {}, ' | '),
				E('span', {}, 'v1.8.4')
			]);
			nodes.appendChild(footer);
			return nodes;
		});
	}
});
