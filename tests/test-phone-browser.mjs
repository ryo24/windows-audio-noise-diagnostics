// Optional real-browser integration test. No npm packages, cloud, real microphone,
// or browser profile belonging to the user is used. Requires Node 22+ and Chrome.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
fs.mkdirSync(path.join(root,'artifacts'),{recursive:true});
const directory=fs.mkdtempSync(path.join(root,'artifacts','phone-browser-'));
const browserPath=process.env.AUDIO_TEST_BROWSER || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
let browser,host,ws,serial=0;const pending=new Map();
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(fn,seconds=20){const end=Date.now()+seconds*1000;while(Date.now()<end){try{const value=await fn();if(value)return value;}catch{}await sleep(100);}throw new Error('Browser workflow timed out');}
function command(method,params={}){return new Promise((resolve,reject)=>{const id=++serial;const timer=setTimeout(()=>{pending.delete(id);reject(new Error(method+' timed out'));},15000);pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({id,method,params}));});}
async function evaluate(expression){const result=await command('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(result.exceptionDetails)throw new Error(result.exceptionDetails.text);return result.result.value;}
try{
  host=spawn('powershell.exe',['-NoProfile','-ExecutionPolicy','Bypass','-File',path.join(root,'tests','Start-PhoneTestHost.ps1'),'-Directory',directory],{cwd:root,windowsHide:true,stdio:['ignore','pipe','pipe']});
  let hostErrors='';host.stderr.on('data',chunk=>{hostErrors+=chunk.toString();});
  await until(()=>fs.existsSync(path.join(directory,'url.txt')),30);
  const url=fs.readFileSync(path.join(directory,'url.txt'),'utf8');
  const profile=path.join(directory,'browser-profile');
  browser=spawn(browserPath,['--headless=new','--remote-debugging-port=0','--remote-allow-origins=http://localhost','--user-data-dir='+profile,'--no-first-run','--no-default-browser-check','--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','about:blank'],{windowsHide:true,stdio:'ignore'});
  await until(()=>fs.existsSync(path.join(profile,'DevToolsActivePort')));
  const port=fs.readFileSync(path.join(profile,'DevToolsActivePort'),'utf8').split('\n')[0];
  const targets=await (await fetch('http://127.0.0.1:'+port+'/json/list')).json();
  const page=targets.find(target=>target.type==='page');
  ws=new WebSocket(page.webSocketDebuggerUrl);await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
  ws.addEventListener('message',event=>{const value=JSON.parse(event.data);const waiter=pending.get(value.id);if(waiter){clearTimeout(waiter.timer);pending.delete(value.id);if(value.error)waiter.reject(new Error(value.error.message));else waiter.resolve(value.result);}});
  await command('Page.enable');await command('Runtime.enable');
  await command('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  await command('Page.navigate',{url});
  await until(()=>evaluate('!!document.getElementById("record-start") && !document.getElementById("direct-controls").hidden'));
  await evaluate('document.getElementById("record-start").click()');
  await until(()=>evaluate('!document.getElementById("record-stop").disabled'));
  await sleep(1600);await evaluate('document.getElementById("record-stop").click()');
  await until(()=>evaluate('!document.getElementById("send").disabled'));
  await evaluate('document.getElementById("confirmed").checked=true;document.getElementById("heard").value="Yes";document.getElementById("note").value="Browser fixture";document.getElementById("send").click()');
  await until(()=>evaluate('document.getElementById("status").textContent.includes("PCへ送信しました")'));
  await until(()=>fs.existsSync(path.join(directory,'received-1.json')));
  const first=JSON.parse(fs.readFileSync(path.join(directory,'received-1.json'),'utf8'));
  assert.equal(first.PreviewConfirmed,true);assert.equal(first.HeardNoise,'Yes');assert.ok(first.Bytes>1000);assert.ok(first.CaptureStartedUtc);
  console.log('PASS: browser-generated fake-microphone recording uploads locally with observation metadata');
  // hidden is also the initial HTML state. Wait for the deferred script to
  // finish installing file handlers, even on a slow LAN or a busy CI runner.
  await command('Network.enable');
  await command('Network.emulateNetworkConditions',{offline:false,latency:200,downloadThroughput:1000000,uploadThroughput:1000000});
  await command('Page.addScriptToEvaluateOnNewDocument',{source:'Object.defineProperty(window,"isSecureContext",{get:()=>false,configurable:true});'});
  await command('Page.navigate',{url});
  await until(()=>evaluate('document.readyState === "complete" && !!document.getElementById("direct-controls") && document.getElementById("direct-controls").hidden && document.getElementById("direct-note").textContent.includes("このLAN接続")'));
  const documentRoot=await command('DOM.getDocument');const input=await command('DOM.querySelector',{nodeId:documentRoot.root.nodeId,selector:'#saved-file'});
  await command('DOM.setFileInputFiles',{nodeId:input.nodeId,files:[path.join(directory,'fixture.wav')]});
  await until(()=>evaluate('!document.getElementById("send").disabled'));
  await evaluate('document.getElementById("send").click()');
  await until(()=>fs.existsSync(path.join(directory,'received-2.json')));
  const second=JSON.parse(fs.readFileSync(path.join(directory,'received-2.json'),'utf8'));assert.equal(second.MimeType,'audio/wav');assert.equal(second.CaptureStartedUtc,'');
  console.log('PASS: insecure-context fallback hides unavailable direct recording and imports a selected local file');
  await command('Network.emulateNetworkConditions',{offline:false,latency:0,downloadThroughput:-1,uploadThroughput:-1});
  const phoneShot=await command('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});fs.writeFileSync(path.join(directory,'phone.png'),Buffer.from(phoneShot.data,'base64'));
  await command('Emulation.setDeviceMetricsOverride',{width:1000,height:1000,deviceScaleFactor:1,mobile:false});await command('Page.navigate',{url:url+'pc'});
  await until(()=>evaluate('!!document.querySelector("#qrcode canvas, #qrcode img")'));
  assert.equal(await evaluate('document.getElementById("pair-link").href'),url);
  const qrShot=await command('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});fs.writeFileSync(path.join(directory,'qr.png'),Buffer.from(qrShot.data,'base64'));
  console.log('PASS: bundled QR renderer creates the pairing page without a remote image or CDN');
  console.log('Browser integration passed. Private test artifacts: '+path.relative(root,directory));
  if(hostErrors.trim())throw new Error('Test host reported an error');
}finally{
  if(ws){try{await command('Browser.close');}catch{}ws.close();}
  for(const waiter of pending.values()){clearTimeout(waiter.timer);waiter.reject(new Error('Browser closed'));}pending.clear();
  fs.writeFileSync(path.join(directory,'stop'),'stop');
  if(host){await Promise.race([new Promise(resolve=>host.once('exit',resolve)),sleep(5000)]);if(host.exitCode===null)host.kill();}
  if(browser && browser.exitCode===null)browser.kill();
}
