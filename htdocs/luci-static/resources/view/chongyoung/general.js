'use strict';
/*
 * luci-app-chongyoung - LuCI view: General settings
 * 描述: ChongYoung 校园网自动认证的 Web UI 界面
 * 功能:
 *  - 显示当前运行状态并支持轮询更新
 *  - 提供重启服务按钮
 *  - 提供账号、密码种子、每日密码列表、计划休眠与高级参数设置
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
	render: function() {
		var m, s, o;

		m = new form.Map('chongyoung', _('ChongYoung Network'), _('Configuration for ChongYoung Campus Network Auto Login'));

		// Status 区块：显示当前脚本运行状态（/tmp/chongyoung_status），并提供重启操作
		s = m.section(form.TypedSection, 'global', _('Status'));
		s.anonymous = true;
		
		o = s.option(form.DummyValue, '_status', _('Current Status'));
		o.rawhtml = true;
		o.default = '<em>' + _('Collecting data...') + '</em>';
		// cfgvalue: 从 /tmp/chongyoung_status 读取状态并用颜色提示严重性（正常=green、重连/失败=red、休眠=orange）
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
				// 读取失败表示服务未运行或文件不存在
				return '<span style="color:grey">' + _('Not Running') + '</span>';
			});
		};
		
		o = s.option(form.Button, '_restart', _('Action'));
		o.inputtitle = _('Restart Service');
		o.inputstyle = 'apply';
		// 点击回调: 调用后端的 restart 操作并展示通知结果
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
		
		// 定期轮询状态文件并更新界面（保持短轮询以便即时反馈）
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
				// 忽略读取错误以保持轮询继续运行
			});
		});

		// General Settings: 基本配置（启用/手机号/密码种子）
		s = m.section(form.TypedSection, 'global', _('General Settings'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'username', _('Phone Number'));
		o.rmempty = false;

		// Password Seed: 若填写则使用此 6 位原始密码生成每日密码，优先于手动列表
		o = s.option(form.Value, 'password_seed', _('Password Seed'), _('Enter your 6-digit original password. If set, the daily password list below will be ignored.'));
		o.rmempty = true;
		o.datatype = 'string';
		o.validate = function(section_id, value) {
			if (value && value.length !== 6) {
				return _('Password seed must be 6 characters long');
			}
			return true;
		};

		// Scheduled Pause: 配置服务的定时休眠，可在学校网维护/离线时自动暂停认证行为
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

		// Daily Passwords: 手动粘贴 31 行每日密码（当未使用 password_seed 时生效）
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

		// Advanced Settings: 高级参数（一般不建议修改，来自 edition.ini）
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

		// Render 完成后追加 footer（项目链接与版本信息）
		return m.render().then(function(nodes) {
			var footer = E('div', { 'class': 'cbi-section', 'style': 'text-align: center; margin-top: 20px; color: #888;' }, [
				E('span', {}, _('Project hosted on ')),
				E('a', { 'href': 'https://github.com/Chizukuo/luci-app-chongyoung', 'target': '_blank', 'style': 'color: #0069b4; text-decoration: none; font-weight: bold;' }, 'GitHub'),
				E('span', {}, ' | '),
				E('span', {}, 'v1.8')
			]);
			nodes.appendChild(footer);
			return nodes;
		});
	}
});
