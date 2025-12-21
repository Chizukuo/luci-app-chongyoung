'use strict';
'require view';
'require form';
'require ui';
'require fs';
'require poll';

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
				}
				return '<span style="color:' + color + '; font-weight:bold">' + status + '</span>';
			}).catch(function() {
				return '<span style="color:grey">' + _('Not Running') + '</span>';
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

		o = s.option(form.Value, 'system', _('System Agent'));
		o = s.option(form.Value, 'prefix', _('Prefix'));
		
		var attrs = ['AidcAuthAttr3', 'AidcAuthAttr4', 'AidcAuthAttr5', 'AidcAuthAttr6', 'AidcAuthAttr8', 'AidcAuthAttr15', 'AidcAuthAttr22', 'AidcAuthAttr23'];
		attrs.forEach(function(attr) {
			o = s.option(form.Value, attr, attr);
		});

		return m.render();
	}
});
