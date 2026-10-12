function photoURL() {
  const c = document.createElement('canvas'); c.width = 1100; c.height = 700; const g = c.getContext('2d');
  let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const sky = g.createLinearGradient(0, 0, 0, 700); sky.addColorStop(0, '#2f6fb0'); sky.addColorStop(0.45, '#e9b27b'); sky.addColorStop(0.7, '#6c8a4b'); sky.addColorStop(1, '#2a3b22');
  g.fillStyle = sky; g.fillRect(0, 0, 1100, 700);
  for (let i = 0; i < 260; i++) { const x = rnd() * 1100, y = rnd() * 700, r = 6 + rnd() * 60; g.fillStyle = `hsla(${Math.floor(rnd() * 360)},${40 + rnd() * 50}%,${25 + rnd() * 55}%,${0.25 + rnd() * 0.45})`; g.beginPath(); g.arc(x, y, r, 0, TAU); g.fill(); }
  for (let i = 0; i < 90; i++) { g.fillStyle = `hsla(${Math.floor(rnd() * 60) + 20},60%,${rnd() > 0.5 ? 92 : 12}%,${0.35 + rnd() * 0.4})`; g.fillRect(rnd() * 1100, rnd() * 700, 2 + rnd() * 70, 2 + rnd() * 10); }
  g.lineWidth = 1.2; for (let i = 0; i < 700; i++) { g.strokeStyle = `rgba(${rnd() > 0.5 ? '255,255,255' : '0,0,0'},${0.1 + rnd() * 0.3})`; g.beginPath(); const x = rnd() * 1100, y = rnd() * 700; g.moveTo(x, y); g.lineTo(x + (rnd() - 0.5) * 40, y + (rnd() - 0.5) * 40); g.stroke(); }
  return c.toDataURL('image/jpeg', 0.85);
}
