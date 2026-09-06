'use strict';
'require baseclass';
'require fs';

return baseclass.extend({
	title: _('FeiYoung Network'),

	load: function() {
		return fs.read('/tmp/feiyoung_status').catch(function() {
			return '';
		});
	},

	render: function(status) {
		if (!status || status.trim() === '') {
			return null;
		}

		status = status.trim();
		var lines = status.split('\n');
		var summary = lines[0];
		var color = '#5cb85c'; // Green
		
		if (summary.indexOf('重连') !== -1 || summary.indexOf('失败') !== -1) {
			color = '#d9534f'; // Red
		} else if (summary.indexOf('休眠') !== -1) {
			color = '#f0ad4e'; // Orange
		} else if (summary === _('Not Running') || summary.indexOf('未运行') !== -1) {
			color = '#777'; // Grey
		}

		var fieldChildren = [
			E('div', { 'style': 'color:' + color + '; font-weight:bold' }, summary)
		];

		if (lines.length > 1) {
			var list = E('ul', { 'style': 'margin:4px 0 0 0; padding-left:16px; font-size:90%; color:#666;' });
			for (var i = 1; i < lines.length; i++) {
				var line = lines[i].trim();
				if (line) {
					list.appendChild(E('li', {}, line));
				}
			}
			fieldChildren.push(list);
		}

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Status')),
				E('div', { 'class': 'cbi-value-field' }, fieldChildren)
			])
		]);
	}
});
