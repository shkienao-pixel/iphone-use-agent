// Page-state adapter, evaluated only in Sela's own Xiaohongshu WKWebView.
// State field names verified against xpzouying/xiaohongshu-mcp's read contract.
// Never read document.cookie, call private APIs, or execute page text as code.
const SelaXHSReader = (() => {
  const unwrap = value => value && typeof value === 'object' && !Array.isArray(value)
    ? (value.value !== undefined ? value.value : value._value !== undefined ? value._value : value) : value;
  const text = (value, max) => typeof value === 'string' ? Array.from(value).slice(0, max).join('') : '';
  const validID = value => typeof value === 'string' && /^[0-9a-fA-F]{24}$/.test(value);
  const user = value => ({ nickname: text(value?.nickname || value?.nickName, 100) });
  function snapshot(action, noteID) {
    if (location.protocol !== 'https:' || location.hostname !== 'www.xiaohongshu.com') return { error: 'origin' };
    const state = window.__INITIAL_STATE__;
    const info = unwrap(state?.user?.userInfo);
    const accountID = info && !info.guest ? (info.userId || info.user_id) : '';
    const account = validID(accountID) ? { id: accountID, name: text(info.nickname || info.nickName, 100) } : null;
    if (action === 'status') return { account };
    if (!account) return { error: 'login' };
    if (action === 'search') {
      const rows = unwrap(state?.search?.feeds);
      if (!Array.isArray(rows)) return { error: 'unsupported', account };
      const feeds = [], seen = new Set();
      for (const row of rows.slice(0, 100)) {
        if (row?.modelType !== 'note' || !validID(row.id) || seen.has(row.id) || !row.noteCard) continue;
        const ref = text(row.xsecToken, 4097);
        if (!ref || Array.from(ref).length > 4096) continue;
        seen.add(row.id);
        feeds.push({ modelType: 'note', id: row.id, xsecToken: ref,
          noteCard: { displayTitle: text(row.noteCard.displayTitle, 300), user: user(row.noteCard.user) } });
        if (feeds.length === 10) break;
      }
      return { account, payload: { feeds } };
    }
    if (action !== 'detail' || !validID(noteID)) return { error: 'unsupported', account };
    const map = unwrap(state?.note?.noteDetailMap);
    const entry = map && Object.values(map).map(unwrap).find(item => item?.note?.noteId === noteID);
    if (!entry) return { error: 'unsupported', account };
    const source = entry.note;
    const note = { noteId: noteID, title: text(source.title, 300), desc: text(source.desc, 12001), user: user(source.user),
      selaBodyTruncated: typeof source.desc === 'string' && Array.from(source.desc).length > 12000 };
    const comments = unwrap(entry.comments), data = { note };
    if (comments && Array.isArray(unwrap(comments.list))) {
      const read = item => ({ id: text(item?.id, 160), content: text(item?.content, 4000), userInfo: user(item?.userInfo) });
      data.comments = { list: unwrap(comments.list).slice(0, 20).map(item => ({ ...read(item),
        subComments: (Array.isArray(unwrap(item?.subComments)) ? unwrap(item.subComments) : []).slice(0, 10).map(read) })) };
    }
    return { account, payload: { feed_id: noteID, data } };
  }
  return { snapshot };
})();
