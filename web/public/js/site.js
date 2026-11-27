// Shared by the legal pages: the signed-in buttons in the top bar, and the contents list beside the text.
(() => {
  const root = document.documentElement;
  // Confirm the signed-in hint quietly (it only changes anything if the hint was wrong).
  fetch('/api/me', { credentials: 'same-origin' }).then(r => {
    const signedIn = r.ok;
    root.classList.toggle('signed-in', signedIn);
    try { signedIn ? localStorage.setItem('cadence:signedIn', '1') : localStorage.removeItem('cadence:signedIn'); } catch {}
    if (signedIn) document.querySelectorAll('[data-start]').forEach(a => { a.href = '/app'; });
  }).catch(() => {});

  // Contents: one link per section heading. Headings without an id get one from their text.
  const toc = document.querySelector('.toc');
  const heads = [...document.querySelectorAll('.doc-body > h2')];
  if (!toc || !heads.length) return;
  const slug = t => t.toLowerCase().replace(/^\d+\.\s*/, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  for (const h of heads) if (!h.id) h.id = slug(h.textContent);
  // A link to one of those sections couldn't find it before it had its id: go there now.
  if (location.hash) document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();
  toc.innerHTML = '<b>Contents</b>' + heads.map(h => `<a href="#${h.id}">${h.textContent.replace(/\s*—.*$/, '')}</a>`).join('');
  const links = new Map([...toc.querySelectorAll('a')].map(a => [a.getAttribute('href').slice(1), a]));
  // The section being read is marked in the list.
  const mark = () => {
    let current = heads[0];
    for (const h of heads) if (h.getBoundingClientRect().top < 200) current = h;
    links.forEach((a, id) => a.classList.toggle('on', id === current.id));
  };
  addEventListener('scroll', mark, { passive: true });
  mark();
})();
