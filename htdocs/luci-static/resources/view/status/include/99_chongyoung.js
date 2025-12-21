'use strict';
'require baseclass';
'require fs';

return baseclass.extend({
	title: _('ChongYoung Network'),

	load: function() {
		return fs.read('/tmp/chongyoung_status').catch(function() {
			return '';
		});
	},

	render: function(status) {
		status = status ? status.trim() : _('Not Running');
		var color = '#5cb85c'; // Green
		
		if (status.indexOf('重连') !== -1 || status.indexOf('失败') !== -1) {
			color = '#d9534f'; // Red
		} else if (status.indexOf('休眠') !== -1) {
			color = '#f0ad4e'; // Orange
		} else if (status === _('Not Running')) {
			color = '#777'; // Grey
		}

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('ChongYoung Network')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Status')),
				E('div', { 'class': 'cbi-value-field', 'style': 'color:' + color + '; font-weight:bold' }, status)
			])
		]);
	}
});
