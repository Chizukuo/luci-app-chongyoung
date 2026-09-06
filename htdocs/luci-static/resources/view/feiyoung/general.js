'use strict';
/*
 * luci-app-feiyoung - LuCI view: General settings (v2)
 * 描述: FeiYoung 校园网自动认证的 Web UI 界面
 * 功能:
 *  - 显示当前运行状态并支持轮询更新
 *  - 提供重启服务按钮
 *  - 提供账号、静态密码、计划休眠与高级参数设置
 */
'require view';
'require form';
'require ui';
'require fs';
'require poll';
'require rpc';

// RPC helper: 调用 LuCI 后端的 setInitAction（用于 restart/stop/start 等操作）
var callInitAction = rpc.declare({
	object: 'luci',
	method: 'setInitAction',
	params: [ 'name', 'action' ],
	expect: { result: false }
});

// 主视图：通过 render() 构建配置页面并返回 DOM 节点
return view.extend({
	load: function() {
		return fs.read('/tmp/feiyoung_status').catch(function() {
			return '';
		});
	},

	render: function(status_initial) {
		var m, s, o;

		m = new form.Map('feiyoung', _('FeiYoung Network'), _('Configuration for FeiYoung Campus Network Auto Login'));

		// Status 区块：显示当前脚本运行状态（/tmp/feiyoung_status），并提供重启操作
		s = m.section(form.TypedSection, 'global', _('Status'));
		s.anonymous = true;

		var initial_status = status_initial ? status_initial.trim() : _('Not Running');
		var initial_color = 'green';
		if (initial_status.indexOf('重连') !== -1 || initial_status.indexOf('失败') !== -1) {
			initial_color = 'red';
		} else if (initial_status.indexOf('休眠') !== -1) {
			initial_color = 'orange';
		} else if (initial_status === _('Not Running')) {
			initial_color = 'grey';
		}

		o = s.option(form.DummyValue, '_status', _('Current Status'));
		o.rawhtml = true;
		o.default = '<span id="feiyoung_status_text" style="color:' + initial_color + '; font-weight:bold">' + initial_status + '</span>';

		o = s.option(form.Button, '_restart', _('Action'));
		o.inputtitle = _('Restart Service');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callInitAction('feiyoung', 'restart').then(function(result) {
				if (result) {
					ui.addNotification(null, E('p', _('Service restarted successfully. Please wait for status update.')), 'info');
				} else {
					ui.addNotification(null, E('p', _('Failed to restart service.')), 'error');
				}
			}).catch(function(e) {
				ui.addNotification(null, E('p', _('Failed to restart service: ') + e.message), 'error');
			});
		};

		// 定期轮询状态文件并更新界面
		poll.add(function() {
			return fs.read('/tmp/feiyoung_status').then(function(status) {
				var el = document.getElementById('feiyoung_status_text');
				if (el) {
					status = status ? status.trim() : _('Not Running');
					var color = 'green';
					if (status.indexOf('重连') !== -1 || status.indexOf('失败') !== -1) {
						color = 'red';
					} else if (status.indexOf('休眠') !== -1) {
						color = 'orange';
					} else if (status === _('Not Running')) {
						color = 'grey';
					}
					el.textContent = status;
					el.style.color = color;
				}
			}).catch(function() {});
		});

		// General Settings: 基本配置（启用/手机号/静态密码）
		s = m.section(form.TypedSection, 'global', _('General Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('Phone Number'));
		o.rmempty = false;

		// Password: 6 位静态密码（直接提交，不再每日算号）
		o = s.option(form.Value, 'password', _('Password'), _('Enter your 6-digit static password.'));
		o.rmempty = true;
		o.datatype = 'string';
		o.password = true;
		o.validate = function(section_id, value) {
			if (value && value.length !== 6) {
				return _('Password must be 6 characters long');
			}
			return true;
		};

		// Scheduled Pause: 配置服务的定时休眠
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

		// Advanced Settings: 高级参数（一般不建议修改）
		s = m.section(form.TypedSection, 'global', _('Advanced Settings'), _('Advanced parameters.') + '<br /><span style="color:red; font-weight:bold">' + _('WARNING: Do not modify unless you know what you are doing!') + '</span>');
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

		o = s.option(form.Value, 'gateway', _('Portal Gateway'), _('Portal base URL. Auto-discovered by default via HTTP redirect; this is a fallback.'));
		o.placeholder = 'http://58.53.199.144:8001';

		o = s.option(form.Value, 'passType', _('Password Type'), _('1 = static password, 2 = dynamic password. Default: 1'));
		o.datatype = 'uinteger';
		o.placeholder = '1';

		// Render 完成后追加 footer（项目链接与版本信息）
		return m.render().then(function(nodes) {
			var footer = E('div', { 'class': 'cbi-section', 'style': 'text-align: center; margin-top: 20px; color: #888;' }, [
				E('span', {}, _('Project hosted on ')),
				E('a', { 'href': 'https://github.com/Chizukuo/luci-app-feiyoung', 'target': '_blank', 'style': 'color: #0069b4; text-decoration: none; font-weight: bold;' }, 'GitHub'),
				E('span', {}, ' | '),
				E('span', {}, 'v2.1.2')
			]);
			nodes.appendChild(footer);
			return nodes;
		});
	}
});
