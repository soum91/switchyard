'use strict';
'require view';
'require form';
'require fs';
'require ui';

function status() {
	return L.resolveDefault(fs.exec('/usr/sbin/lightsout', [ 'status' ]), {}).then(function(r) {
		var out = {};
		((r && r.stdout) || '').trim().split(/\s+/).forEach(function(kv) {
			var i = kv.indexOf('=');
			if (i > 0)
				out[kv.substring(0, i)] = kv.substring(i + 1);
		});
		return out;
	});
}

function describe(s) {
	if (!s.lights)
		return _('Unknown');
	var txt = s.lights == 'off' ? _('Lights are off') : _('Lights are on');
	if (s.override == '1')
		txt += ' ' + _('(switched by hand until the next scheduled change)');
	else if (s.enabled == '1')
		txt += ' ' + (s.night == '1' ? _('(night: off until %s)').format(s.on) : _('(day: off at %s)').format(s.off));
	return txt + ' · ' + _('router time %s').format(s.time);
}

function validTime(id, v) {
	return /^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(v || '') ? true : _('Use 24-hour HH:MM, like 23:00');
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.list('/sys/class/leds'), []),
			status()
		]);
	},

	render: function(data) {
		var leds = (data[0] || []).map(function(e) { return e.name; }).filter(function(n) { return n.indexOf('mt76') != 0; }).sort();
		var m, s, o;

		m = new form.Map('lightsout', _('Router lights'),
			_('Turns the router\'s lights off at night. The schedule is checked again at boot, when the clock syncs and every 5 minutes, so the lights stay off if the router restarts during the night.'));

		s = m.section(form.NamedSection, 'main', 'lightsout');

		o = s.option(form.DummyValue, '_state', _('Right now'));
		o.cfgvalue = function() { return describe(data[1]); };
		o.write = function() {};

		o = s.option(form.Button, '_on', _('Switch now'));
		o.inputtitle = _('Lights on');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return fs.exec('/usr/sbin/lightsout', [ 'on' ]).then(function() { location.reload(); });
		};

		o = s.option(form.Button, '_off', ' ');
		o.inputtitle = _('Lights off');
		o.inputstyle = 'reset';
		o.onclick = function() {
			return fs.exec('/usr/sbin/lightsout', [ 'off' ]).then(function() { location.reload(); });
		};

		o = s.option(form.Flag, 'enabled', _('Night schedule'));
		o.rmempty = false;

		o = s.option(form.Value, 'off', _('Lights off at'), _('24-hour time, router clock'));
		o.placeholder = '23:00';
		o.validate = validTime;
		o.depends('enabled', '1');

		o = s.option(form.Value, 'on', _('Lights on at'));
		o.placeholder = '07:00';
		o.validate = validTime;
		o.depends('enabled', '1');

		o = s.option(form.MultiValue, 'led', _('Which lights'), _('Leave empty for all of them.'));
		leds.forEach(function(l) { o.value(l, l); });
		o.optional = true;

		return m.render();
	}
});
