const users = [
  {name:'operador01', limit:2, active:1, expiry:'2026-12-10', state:'Activo'},
  {name:'cliente_07', limit:2, active:2, expiry:'2026-11-13', state:'Por vencer'},
  {name:'cliente_12', limit:1, active:0, expiry:'2026-11-13', state:'Por vencer'},
  {name:'cliente_demo', limit:1, active:1, expiry:'2026-11-16', state:'Activo'},
  {name:'usuario_03', limit:3, active:0, expiry:'2026-11-18', state:'Activo'},
  {name:'cuenta_suspendida', limit:1, active:0, expiry:'2026-12-01', state:'Suspendido'}
];
const services = [
  {name:'OpenSSH', detail:'Puerto 22', status:'Activo', symbol:'S'},
  {name:'Dropbear', detail:'Puerto 2222', status:'Activo', symbol:'D'},
  {name:'Despachador WS', detail:'Puertos 80 / 8080 / 8880', status:'Activo', symbol:'W'},
  {name:'BadVPN UDPGW', detail:'Puerto 7300', status:'Inactivo', symbol:'U'},
  {name:'Auto-limitador', detail:'Vigilancia de sesiones', status:'Activo', symbol:'L'}
];
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const safeText = value => String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
function statusMarkup(state) {
  const cls = state === 'Activo' || state === 'Online' ? 'status-ok' : state === 'Inactivo' || state === 'Suspendido' ? 'status-down' : 'status-warn';
  return `<span class="status-pill ${cls}"><i></i>${safeText(state)}</span>`;
}
function renderUsers() {
  const query = ($('#userSearch')?.value || '').trim().toLowerCase();
  const filter = $('#userFilter')?.value || 'all';
  const rows = users.filter(user => user.name.toLowerCase().includes(query) && (filter === 'all' || user.state === filter));
  $('#userRows').innerHTML = rows.map(user => `<tr><td><strong>${safeText(user.name)}</strong></td><td>${user.limit}</td><td>${user.active} / ${user.limit}</td><td>${safeText(user.expiry)}</td><td>${statusMarkup(user.state)}</td><td><button class="text-link row-action" data-demo-action>···</button></td></tr>`).join('') || '<tr><td colspan="6">No hay resultados.</td></tr>';
  $$('.row-action', $('#userRows')).forEach(button => button.addEventListener('click', showDemoMessage));
}
function renderLimits() {
  $('#limitCards').innerHTML = users.slice(0,5).map(user => `<article class="panel-card info-card"><small>USUARIO</small><strong>${safeText(user.name)}</strong><span>${user.active} de ${user.limit} sesiones · datos de ejemplo</span><div class="progress"><i style="width:${Math.min(100, user.active / user.limit * 100)}%"></i></div></article>`).join('');
}
function renderExpiry() {
  $('#expiryRows').innerHTML = users.slice().sort((a,b) => a.expiry.localeCompare(b.expiry)).map(user => `<tr><td>${safeText(user.name)}</td><td>${safeText(user.expiry)}</td><td>${user.state === 'Por vencer' ? 'Próximamente' : '—'}</td><td>${statusMarkup(user.state)}</td></tr>`).join('');
}
function renderServices() {
  $('#serviceCards').innerHTML = services.map(service => `<article class="panel-card service-row"><span class="service-symbol ws-symbol">${safeText(service.symbol)}</span><span class="service-info"><strong>${safeText(service.name)}</strong><small>${safeText(service.detail)}</small></span>${statusMarkup(service.status)}</article>`).join('');
}
function showDemoMessage(event) {
  event?.preventDefault();
  const toast = $('#toast');
  toast.textContent = 'Acción desactivada: este panel está en modo demostración.';
  toast.classList.add('show');
  clearTimeout(showDemoMessage.timer);
  showDemoMessage.timer = setTimeout(() => toast.classList.remove('show'), 2600);
}
function navigate() {
  const page = location.hash.replace('#','') || 'dashboard';
  const target = $(`#page-${page}`) ? page : 'dashboard';
  $$('.page').forEach(section => section.classList.toggle('active', section.id === `page-${target}`));
  $$('.nav-link').forEach(link => link.classList.toggle('active', link.dataset.page === target));
  const active = $(`.nav-link[data-page="${target}"]`);
  $('#currentCrumb').textContent = active ? active.textContent.trim().replace(/\d+$/, '').trim() : 'Resumen';
  $('#sidebar').classList.remove('open');
  window.scrollTo(0,0);
}
renderUsers(); renderLimits(); renderExpiry(); renderServices(); navigate();
window.addEventListener('hashchange', navigate);
$('#userSearch').addEventListener('input', renderUsers);
$('#userFilter').addEventListener('change', renderUsers);
$('#menuToggle').addEventListener('click', () => $('#sidebar').classList.toggle('open'));
$('#refreshBtn').addEventListener('click', showDemoMessage);
$$('[data-demo-action]').forEach(button => button.addEventListener('click', showDemoMessage));
$$('a[data-page]').forEach(link => link.addEventListener('click', () => { if (location.hash === link.getAttribute('href')) navigate(); }));
