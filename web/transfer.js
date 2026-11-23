'use strict';
// Only bounded categories and counters leave this page. Never include pairing
// URLs, names, notes, raw errors, headers, cookies or recording contents.
window.PhoneTransfer = (() => {
  const attempts = [];
  let active = null, xhr = null;
  const browserMatch = navigator.userAgent.match(/(Firefox|Edg|Chrome|Version)\/(\d+)/);
  const browser = {family: browserMatch ? ({Edg:'Edge',Version:'Safari'}[browserMatch[1]] || browserMatch[1]) : 'Unknown', major: browserMatch ? Number(browserMatch[2]) : 0};
  const stages = new Set(['Selected','FileReadable','FileReadError','RequestStarted','UploadProgress','UploadBodySent','ResponseReceived','Completed','HttpError','NetworkError','Timeout','Aborted','InvalidResponse','SecurityPolicyBlocked']);
  function event(stage, loadedBytes = 0, status = 0) {
    if (!active || !stages.has(stage)) return;
    const entry = {stage, elapsedMs: Math.round(performance.now() - active.clock), loadedBytes, status};
    // Keep the first event and the most recent details, including final state.
    if (active.events.length >= 32) active.events.splice(1, 1);
    active.events.push(entry);
    document.dispatchEvent(new Event('transfer-state'));
  }
  function begin(kind, file) {
    const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
    active = {id: Array.from(bytes, b => b.toString(16).padStart(2,'0')).join(''), kind, startedUtc: new Date().toISOString(), clock: performance.now(), outcome:'Pending', fileBytes:file ? file.size : 0, mediaKind:file ? (file.type.startsWith('audio/') ? 'Audio' : file.type.startsWith('video/') ? 'Video' : 'Other') : 'None', events:[]};
    attempts.push(active); if (attempts.length > 10) attempts.shift();
    event('Selected'); return active;
  }
  function request(route, body, headers) {
    return new Promise(resolve => {
      xhr = new XMLHttpRequest(); let lastProgress = -1000;
      const finish = result => { xhr = null; resolve(result); };
      xhr.open(body ? 'POST' : 'GET', new URL(route, location.href));
      xhr.timeout = body ? 190000 : 10000;
      for (const [name,value] of Object.entries(headers || {})) xhr.setRequestHeader(name,value);
      if (body) {
        xhr.upload.addEventListener('progress', e => {
          if (performance.now() - lastProgress >= 1000) { lastProgress = performance.now(); event('UploadProgress', e.loaded); }
        });
        xhr.upload.addEventListener('load', e => event('UploadBodySent', e.loaded));
      }
      xhr.addEventListener('load', () => {
        const status = xhr.status; event('ResponseReceived',0,status);
        if (status < 200 || status >= 300) { event('HttpError',0,status); finish({ok:false, reason:'HttpError', status}); return; }
        let data; try { data = JSON.parse(xhr.responseText); } catch { event('InvalidResponse',0,status); finish({ok:false,reason:'InvalidResponse',status}); return; }
        if (!data || (body ? data.received !== true : data.ready !== true)) { event('InvalidResponse',0,status); finish({ok:false,reason:'InvalidResponse',status}); return; }
        event('Completed',body ? body.size : 0,status); finish({ok:true,reason:'Completed',status});
      });
      for (const [type,reason] of [['error','NetworkError'],['timeout','Timeout'],['abort','Aborted']]) xhr.addEventListener(type,() => {event(reason);finish({ok:false,reason,status:0});});
      event('RequestStarted'); xhr.send(body || null);
    });
  }
  async function run(kind, file, headers) {
    if (active && active.outcome === 'Pending') return {ok:false,reason:'Busy',status:0};
    const attempt = begin(kind,file);
    let result;
    try {
      if (file) { await file.slice(0,1).arrayBuffer(); event('FileReadable'); }
      result = await request(file ? 'upload' : 'health',file,file ? {...headers,'X-Upload-Attempt':attempt.id} : {});
    } catch { xhr=null; const reason = file && !attempt.events.some(e=>e.stage==='FileReadable') ? 'FileReadError' : 'NetworkError'; event(reason); result={ok:false,reason,status:0}; }
    attempt.outcome=result.reason; document.dispatchEvent(new Event('transfer-state'));
    return result;
  }
  document.addEventListener('securitypolicyviolation', e => { if (active && active.outcome==='Pending' && e.effectiveDirective === 'connect-src') event('SecurityPolicyBlocked'); });
  return {
    upload:(file,headers)=>run('Upload',file,headers), check:()=>run('Health',null,{}),
    cancel:()=>{if(xhr)xhr.abort();},
    get busy(){return !!active && active.outcome==='Pending';},
    getDiagnostics:()=>({schemaVersion:1,kind:'BrowserUploadDiagnostics',browser,secureContext:window.isSecureContext,transportProtocol:location.protocol==='https:'?'HTTPS':'HTTP',online:navigator.onLine,attempts:attempts.map(({clock,...item})=>({...item,events:item.events.map(e=>({...e}))}))})
  };
})();
