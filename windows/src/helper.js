const address = document.querySelector('#address');
document.querySelector('form').onsubmit = e => { e.preventDefault(); window.vidtuck.send({ action: 'helperGo', url: address.value.trim() }); };
document.querySelector('#back').onclick = () => window.vidtuck.send({ action: 'helperBack' });
document.querySelector('#read').onclick = () => window.vidtuck.send({ action: 'helperRead' });
window.vidtuck.onMessage(m => { if (m.type === 'address') address.value = m.payload; if (m.type === 'status') document.querySelector('#status').textContent = m.payload; });
