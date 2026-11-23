'use strict';
const $ = id => document.getElementById(id);
const maximumBytes = 128 * 1024 * 1024;
let selected = null, previewUrl = null, recorder = null, mediaStream = null, chunks = [];
let captureStarted = '', captureEnded = '', stopTimer = null;
function setStatus(message) { $('status').textContent = message; }
function selectFile(file) {
  if (!file) return;
  if (file.size === 0 || file.size > maximumBytes) { selected = null; $('send').disabled = true; $('preview').hidden = true; $('file-status').textContent = '送信できる記録は選択されていません。'; setStatus('記録が空か128MBを超えています。短く録音・撮影し直してください。'); return; }
  selected = file;
  if (previewUrl) URL.revokeObjectURL(previewUrl);
  previewUrl = URL.createObjectURL(file);
  $('preview').src = previewUrl; $('preview').hidden = false;
  $('file-status').textContent = `選択した記録：${(file.size / 1024 / 1024).toFixed(1)} MB。送信前に再生して確認できます。`;
  $('confirmed').checked = false; $('send').disabled = false;
  setStatus('選択した記録は、送信ボタンを押すまでPCへ送りません。');
}
for (const id of ['audio-file', 'video-file', 'saved-file']) $(id).addEventListener('change', event => { captureStarted = ''; captureEnded = ''; selectFile(event.target.files[0]); });
const canRecord = window.isSecureContext && navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder;
$('direct-controls').hidden = !canRecord;
$('direct-note').textContent = canRecord ? 'このブラウザーではページ内の録音が利用できます。録音ボタンを押すとマイク許可を求めます。' : 'このLAN接続ではブラウザー内マイク録音を使えません。下のボタンで端末の録音・カメラを開くか、保存済みファイルを選んでください。';
$('record-start').addEventListener('click', async () => {
  selected = null; $('send').disabled = true; captureStarted = ''; captureEnded = '';
  $('record-start').disabled = true;
  for (const id of ['audio-file', 'video-file', 'saved-file']) $(id).disabled = true;
  try {
    mediaStream = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: false, noiseSuppression: false, autoGainControl: false}, video: false});
    const mime = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus'].find(type => MediaRecorder.isTypeSupported(type));
    recorder = new MediaRecorder(mediaStream, mime ? {mimeType: mime} : undefined); chunks = [];
    recorder.addEventListener('dataavailable', event => { if (event.data.size) chunks.push(event.data); });
    recorder.addEventListener('stop', () => {
      captureEnded = new Date().toISOString();
      selectFile(new Blob(chunks, {type: recorder.mimeType}));
      mediaStream.getTracks().forEach(track => track.stop()); mediaStream = null;
      $('record-start').disabled = false; $('record-stop').disabled = true; clearTimeout(stopTimer);
      for (const id of ['audio-file', 'video-file', 'saved-file']) $(id).disabled = false;
    });
    recorder.start(1000); captureStarted = new Date().toISOString(); captureEnded = '';
    $('record-start').disabled = true; $('record-stop').disabled = false;
    stopTimer = setTimeout(() => { if (recorder.state !== 'inactive') recorder.stop(); }, 300000);
    setStatus('録音中。スピーカーの音を記録したら停止してください（最大5分）。');
  } catch { if (mediaStream) mediaStream.getTracks().forEach(track => track.stop()); $('record-start').disabled = false; for (const id of ['audio-file', 'video-file', 'saved-file']) $(id).disabled = false; setStatus('マイクを使えませんでした。端末の録音・カメラ、または保存済みファイルを利用してください。'); }
});
$('record-stop').addEventListener('click', () => { if (recorder && recorder.state !== 'inactive') recorder.stop(); });
function showTransferResult(result, check = false) {
  if (result.ok) { setStatus(check ? 'PCの受付からHTTP応答がありました。ファイル送信とは別の確認です。' : 'PCへ送信しました。PCアプリの「4 聞き直し・結果」で確認できます。スマホの元ファイルは消しません。'); return; }
  const messages = {
    FileReadError:'選択したファイルを読み出せませんでした。端末に保存してから「保存済みの音声・動画を選択」で選び直してください。',
    NetworkError:'HTTP応答を確認できません。スマホの接続許可・受付・通信経路等が候補ですが、原因は未確定です。',
    Timeout:'応答待ちの制限時間に達しました。送信途中か保存後かはPC側の記録も確認してください。',
    Aborted:'送信を中止しました。PCで保存済みの場合もあるため、再送前にPCの一覧を確認してください。',
    InvalidResponse:'PCの応答形式を確認できませんでした。PC側の受信一覧も確認してください。'
  };
  const httpMessages={400:'PCが要求を受け付けませんでした。',404:'受付URLが無効か期限切れの可能性があります。最新QRを開き直してください。',413:'ファイルが128MBを超えています。短く撮影し直してください。',415:'PCがこの形式を受け付けません。別の音声・動画を選んでください。',429:'PCの受付上限に達しました。受信一覧を確認し、必要なら受付を開き直してください。'};
  setStatus((result.status ? `HTTP ${result.status}：`+(httpMessages[result.status] || 'PCが送信を受け付けませんでした。') : messages[result.reason] || '送信を完了できませんでした。')+'\n「送信ログを保存」とPCの「接続診断を保存」でログを持ち帰れます。元の記録は残っています。');
}
document.addEventListener('transfer-state', () => {
  const busy=PhoneTransfer.busy;
  $('send').disabled=busy || !selected; $('check-receiver').disabled=busy; $('cancel-send').disabled=!busy;
  for (const id of ['audio-file','video-file','saved-file','record-start']) $(id).disabled=busy || !!mediaStream;
  const attempts=PhoneTransfer.getDiagnostics().attempts, attempt=attempts[attempts.length-1], last=attempt && attempt.events[attempt.events.length-1];
  if(busy && last && last.stage==='UploadProgress') setStatus(`送信中：ブラウザーの送出量 ${(last.loadedBytes/1024/1024).toFixed(1)} MB。PCでの保存完了はまだ未確認です。`);
  if(busy && last && last.stage==='UploadBodySent') setStatus('ブラウザーがファイルを送出しました。PCで保存したという応答を待っています。');
});
$('send').addEventListener('click', async () => {
  if (!selected || PhoneTransfer.busy) return;
  setStatus('ファイルを読み出し、PCへ送信します。画面を閉じずにお待ちください。');
  const result=await PhoneTransfer.upload(selected,{
    'Content-Type':'application/octet-stream','X-Client-Sent-Utc':new Date().toISOString(),
    'X-Capture-Started-Utc':captureStarted,'X-Capture-Ended-Utc':captureEnded,
    'X-Preview-Confirmed':String($('confirmed').checked),'X-Heard-Noise':$('heard').value,'X-Note':encodeURIComponent($('note').value)
  });
  showTransferResult(result);
});
$('check-receiver').addEventListener('click', async () => {setStatus('PCの受付へ接続を確認しています。');showTransferResult(await PhoneTransfer.check(),true);});
$('cancel-send').addEventListener('click',()=>PhoneTransfer.cancel());
$('download-diagnostics').addEventListener('click',()=>{
  const url=URL.createObjectURL(new Blob([JSON.stringify(PhoneTransfer.getDiagnostics(),null,2)],{type:'application/json'}));
  const link=document.createElement('a');link.href=url;link.download='audio-noise-transfer_'+new Date().toISOString().replace(/[^0-9TZ]/g,'')+'.json';link.click();setTimeout(()=>URL.revokeObjectURL(url),10000);
});
window.addEventListener('pagehide', () => { PhoneTransfer.cancel(); if (mediaStream) mediaStream.getTracks().forEach(track => track.stop()); });
