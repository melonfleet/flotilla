/* Mockup behaviour: appearance switching, page nav, notes panel, and just
   enough interactivity (tabs, menus, sheets, wizard steps, row selection)
   for the design direction to be judged by clicking rather than reading. */
(function () {
  var PAGES = [
    ['index.html', 'Overview'],
    ['menubar.html', 'Menu bar'],
    ['main-window.html', 'Main window'],
    ['container-detail.html', 'Container'],
    ['fleet.html', 'Fleet'],
    ['settings.html', 'Settings'],
    ['onboarding.html', 'First run']
  ];

  /* ---- appearance ---------------------------------------------------- */
  var MODES = ['auto', 'light', 'dark'];
  var mql = window.matchMedia('(prefers-color-scheme: dark)');

  function appearance() {
    var p = localStorage.getItem('flotilla-appearance');
    return MODES.indexOf(p) < 0 ? 'auto' : p;
  }

  function resolve() {
    var pref = appearance();
    var dark = pref === 'dark' || (pref === 'auto' && mql.matches);
    document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
    document.querySelectorAll('[data-appearance-label]').forEach(function (l) {
      l.textContent = pref === 'auto' ? 'Auto' : (dark ? 'Dark' : 'Light');
    });
    /* onboarding cards, the Settings segmented control — any picker on the page */
    document.querySelectorAll('[data-appearance-set]').forEach(function (o) {
      o.classList.toggle('on', o.dataset.appearanceSet === pref);
      var mark = o.querySelector('.radio');
      if (mark) mark.classList.toggle('on', o.dataset.appearanceSet === pref);
    });
  }
  mql.addEventListener('change', resolve);
  resolve();

  function setAppearance(v) {
    if (MODES.indexOf(v) < 0) return;
    localStorage.setItem('flotilla-appearance', v);
    resolve();
  }

  function cycleAppearance() {
    setAppearance(MODES[(MODES.indexOf(appearance()) + 1) % MODES.length]);
  }

  /* ---- mockup navigator + notes panel -------------------------------- */
  function ic(id, cls) {
    return '<svg class="ic ' + (cls || '') + '" aria-hidden="true"><use href="#' + id + '"/></svg>';
  }
  var here = (location.pathname.split('/').pop() || 'index.html');

  function buildChrome() {
    var nav = document.createElement('div');
    nav.className = 'mocknav';
    var html = '<span class="brandmark">' + ic('i-sails') + 'Flotilla mockups</span>';
    PAGES.forEach(function (p) {
      html += '<a href="' + p[0] + '"' + (p[0] === here ? ' class="on"' : '') + '>' + p[1] + '</a>';
    });
    html += '<span class="divider"></span>' +
      '<a data-act="appearance" title="Light / Dark / Auto">' + ic('i-eye') +
      ' <span data-appearance-label>Auto</span></a>';
    if (document.getElementById('page-notes')) {
      html += '<a data-act="notes">' + ic('i-info') + ' Notes</a>';
    }
    nav.innerHTML = html;
    document.body.appendChild(nav);

    var tpl = document.getElementById('page-notes');
    if (tpl) {
      var panel = document.createElement('aside');
      panel.className = 'notes';
      panel.id = 'notes-panel';
      panel.innerHTML = '<span class="close-notes" data-act="notes">' + ic('i-x') + '</span>' + tpl.innerHTML;
      document.body.appendChild(panel);
    }
    resolve();
  }

  /* ---- generic interactions ------------------------------------------ */
  function closeAllMenus() {
    document.querySelectorAll('[data-menu-panel].shown').forEach(function (m) {
      m.classList.remove('shown');
      m.style.display = 'none';
    });
  }

  document.addEventListener('click', function (e) {
    var t = e.target;

    var act = t.closest('[data-act]');
    if (act) {
      if (act.dataset.act === 'appearance') { cycleAppearance(); return; }
      if (act.dataset.act === 'notes') {
        var p = document.getElementById('notes-panel');
        if (p) p.classList.toggle('open');
        return;
      }
    }

    /* explicit appearance pick — before the generic radio/seg handlers so the
       whole card is clickable, including its radio dot */
    var pick = t.closest('[data-appearance-set]');
    if (pick) {
      setAppearance(pick.dataset.appearanceSet);
      e.preventDefault();
      return;
    }

    /* switches / checkboxes / radios */
    var tog = t.closest('.switch:not(.locked), .check:not(.locked), .radio');
    if (tog) {
      if (tog.classList.contains('radio')) {
        var group = tog.closest('[data-radio-group]');
        if (group) group.querySelectorAll('.radio').forEach(function (r) { r.classList.remove('on'); });
      }
      tog.classList.toggle('on');
      tog.classList.remove('mixed');
      return;
    }

    /* segmented controls */
    var segItem = t.closest('.seg > *');
    if (segItem && segItem.parentElement.hasAttribute('data-seg')) {
      Array.prototype.forEach.call(segItem.parentElement.children, function (c) { c.classList.remove('on'); });
      segItem.classList.add('on');
      var sync = segItem.parentElement.dataset.segSync;
      if (sync) {
        var target = document.querySelector(sync);
        if (target) target.innerHTML = segItem.dataset.token || '';
      }
      return;
    }

    /* tab bars: [data-tabs] > [data-tab="x"] toggles [data-panel="x"] */
    var tab = t.closest('[data-tab]');
    if (tab) {
      var bar = tab.closest('[data-tabs]');
      var scope = document.querySelector(bar.dataset.tabs) || document;
      bar.querySelectorAll('[data-tab]').forEach(function (x) { x.classList.remove('on'); });
      tab.classList.add('on');
      scope.querySelectorAll('[data-panel]').forEach(function (p) {
        p.classList.toggle('on', p.dataset.panel === tab.dataset.tab);
      });
      e.preventDefault();
      return;
    }

    /* wizard steps */
    var go = t.closest('[data-step-go]');
    if (go) {
      var n = go.dataset.stepGo;
      document.querySelectorAll('[data-step]').forEach(function (s) {
        s.classList.toggle('on', s.dataset.step === n);
      });
      document.querySelectorAll('[data-rail-step]').forEach(function (r) {
        var i = +r.dataset.railStep, cur = +n;
        r.classList.toggle('done', i < cur);
        r.classList.toggle('current', i === cur);
      });
      e.preventDefault();
      return;
    }

    /* open / close overlays (sheets, dialogs, popovers) */
    var opener = t.closest('[data-open]');
    if (opener) {
      var el = document.querySelector(opener.dataset.open);
      if (el) el.style.display = 'flex';
      e.preventDefault();
      return;
    }
    if (t.closest('[data-close]') || t.classList.contains('scrim')) {
      var sc = t.closest('.scrim');
      if (sc) sc.style.display = 'none';
      return;
    }

    /* dropdown menus anchored to a button */
    var mBtn = t.closest('[data-menu]');
    if (mBtn) {
      var panel2 = document.querySelector(mBtn.dataset.menu);
      var wasShown = panel2 && panel2.classList.contains('shown');
      closeAllMenus();
      if (panel2 && !wasShown) { panel2.classList.add('shown'); panel2.style.display = 'block'; }
      e.preventDefault();
      return;
    }
    closeAllMenus();

    /* list row selection */
    var row = t.closest('tr[data-href], tr[data-selectable], [data-card-select]');
    if (row) {
      var container = row.closest('tbody, [data-select-scope]');
      if (container) {
        container.querySelectorAll('.focused, .card.sel').forEach(function (r) {
          r.classList.remove('focused');
          if (r.hasAttribute('data-card-select')) r.classList.remove('sel');
        });
      }
      if (row.hasAttribute('data-card-select')) row.classList.add('sel');
      else row.classList.add('focused');
    }
  });

  document.addEventListener('dblclick', function (e) {
    var row = e.target.closest('[data-href]');
    if (row) location.href = row.dataset.href;
  });

  /* right-click context menu (proves the Copy submenu / row actions idea) */
  document.addEventListener('contextmenu', function (e) {
    var host = e.target.closest('[data-ctx]');
    if (!host) return;
    var menu = document.querySelector(host.dataset.ctx);
    if (!menu) return;
    e.preventDefault();
    closeAllMenus();
    menu.style.display = 'block';
    menu.classList.add('shown');
    var r = menu.getBoundingClientRect();
    var x = Math.min(e.clientX, window.innerWidth - r.width - 12);
    var y = Math.min(e.clientY, window.innerHeight - r.height - 12);
    menu.style.left = x + 'px';
    menu.style.top = y + 'px';
  });

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    closeAllMenus();
    var open = Array.prototype.filter.call(document.querySelectorAll('.scrim'), function (s) {
      return s.style.display === 'flex';
    });
    if (open.length) open[open.length - 1].style.display = 'none';
    var p = document.getElementById('notes-panel');
    if (p) p.classList.remove('open');
  });

  /* a log pane that looks like it is streaming */
  function streamLogs() {
    var view = document.querySelector('[data-stream]');
    if (!view) return;
    var lines = JSON.parse(view.dataset.stream || '[]');
    var i = 0;
    setInterval(function () {
      if (!document.querySelector('[data-follow].on')) return;
      var l = lines[i % lines.length];
      i++;
      var t = new Date();
      var ts = String(t.getHours()).padStart(2, '0') + ':' + String(t.getMinutes()).padStart(2, '0') +
               ':' + String(t.getSeconds()).padStart(2, '0') + '.' + String(t.getMilliseconds()).padStart(3, '0');
      var div = document.createElement('div');
      div.className = 'ln';
      div.innerHTML = '<span class="ts">' + ts + '</span><span class="lvl-' + l[0] + '">' + l[1] + '</span>';
      var caret = view.querySelector('.caret-line');
      view.insertBefore(div, caret);
      view.scrollTop = view.scrollHeight;
    }, 1800);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { buildChrome(); streamLogs(); });
  } else { buildChrome(); streamLogs(); }
})();
