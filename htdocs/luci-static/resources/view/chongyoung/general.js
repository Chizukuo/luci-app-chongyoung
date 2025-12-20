'use strict';
'require view';
'require form';
'require ui';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('chongyoung', _('ChongYoung Network'), _('Configuration for ChongYoung Campus Network Auto Login'));

		s = m.section(form.TypedSection, 'global', _('General Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('Phone Number'));
		o.rmempty = false;

		s = m.section(form.TypedSection, 'passwords', _('Daily Passwords'), _('Paste the 31 generated passwords here. One per line.'));
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

		s = m.section(form.TypedSection, 'global', _('Advanced Settings'), _('System parameters from edition.ini'));
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
