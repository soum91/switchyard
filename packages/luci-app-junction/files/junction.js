'use strict';
'require view';
'require form';
'require fs';
'require uci';
'require network';

function statusData() {
	return L.resolveDefault(fs.exec('/usr/sbin/junction', [ 'status' ]), {}).then(function(r) {
		try { return JSON.parse((r && r.stdout) || '{}'); } catch (e) { return {}; }
	});
}

function renderStatus(st) {
	var ups = st.uplinks || [];
	if (!ups.length)
		return E('p', {}, _('No sources yet. Add them below.'));
	var rows = ups.map(function(u) {
		var state = !u.enabled ? _('Off') : u.healthy ? (st.active == u.iface ? _('In use (main)') : _('In use')) : (u.reason || _('Down'));
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, [ E('strong', {}, u.name), E('br'), E('small', {}, u.iface + (u.ssid ? ' · ' + u.ssid : '')) ]),
			E('td', { 'class': 'td', 'style': 'color:' + (u.healthy ? '#2a9d55' : '#c0392b') }, state),
			E('td', { 'class': 'td' }, u.share + '%'),
			E('td', { 'class': 'td' }, u.signal != null ? u.signal + ' dBm' : '–'),
			E('td', { 'class': 'td' }, u.rate != null ? u.rate + ' Mbit/s' : '–'),
			E('td', { 'class': 'td' }, (u.rtt != null ? u.rtt + ' ms' : '–') + ' · ' + u.loss + '% loss')
		]);
	});
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Source')), E('th', { 'class': 'th' }, _('State')),
			E('th', { 'class': 'th' }, _('Share of new connections')), E('th', { 'class': 'th' }, _('Signal')),
			E('th', { 'class': 'th' }, _('Link rate')), E('th', { 'class': 'th' }, _('Ping'))
		])
	].concat(rows));
}

return view.extend({
	load: function() {
		return Promise.all([
			statusData(),
			L.resolveDefault(fs.read('/tmp/junction.log'), ''),
			network.getNetworks()
		]);
	},

	render: function(data) {
		var st = data[0], logtxt = (data[1] || '').trim().split('\n').slice(-15).reverse().join('\n');
		var nets = data[2] || [];
		var m, s, o;

		m = new form.Map('junction', _('Junction'),
			_('Uses several internet sources at once. Each new connection goes out one source, chosen so the same device talking to the same site always uses the same one; different devices and sites are spread by weight. A source is dropped when its internet dies, it loses too many pings, or its signal stays too weak, and comes back once it has been good for a few checks.') + ' ' +
			_('To add a Wi-Fi source: Network › Wireless › Scan on the radio that is still free › Join, firewall zone wan, then add the new interface here. Each radio can hold one source.'));

		s = m.section(form.NamedSection, 'main', 'junction', _('Now'));
		o = s.option(form.DummyValue, '_status');
		o.rawhtml = true;
		o.cfgvalue = function() { return ''; };
		o.render = function() { return E('div', { 'class': 'cbi-value' }, renderStatus(st)); };

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('balance', _('Use every working source (spread connections)'));
		o.value('failover', _('Use one source, switch when it fails (top of the list first)'));

		o = s.option(form.Value, 'min_signal', _('Drop a source below'), _('dBm, after 3 checks in a row'));
		o.datatype = 'range(-100,-40)';
		o.placeholder = '-82';

		o = s.option(form.Value, 'max_loss', _('Drop a source losing more than'), _('% of pings'));
		o.datatype = 'range(5,90)';
		o.placeholder = '30';

		o = s.option(form.Value, 'interval', _('Check every'), _('seconds'));
		o.datatype = 'range(2,60)';
		o.placeholder = '5';

		s = m.section(form.TypedSection, 'uplink', _('Sources'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', _('On'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('Name'));

		o = s.option(form.ListValue, 'iface', _('Interface'));
		nets.forEach(function(n) {
			var name = n.getName();
			if (name != 'lan' && name != 'loopback' && n.getProtocol() != 'wireguard')
				o.value(name, name + ' (' + n.getProtocol() + ')');
		});

		o = s.option(form.Value, 'weight', _('Weight'), _('"auto" follows the link rate; or a fixed number (e.g. 70 and 30)'));
		o.placeholder = 'auto';

		return Promise.resolve(m.render()).then(function(node) {
			node.appendChild(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Recent changes')),
				E('pre', { 'style': 'white-space:pre-wrap' }, logtxt || _('Nothing yet.'))
			]));
			return node;
		});
	}
});
