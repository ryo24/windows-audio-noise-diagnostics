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
$('send').addEventListener('click', async () => {
  if (!selected) return;
  $('send').disabled = true; setStatus('PCへ送信中です。画面を閉じずにお待ちください。');
  try {
    const response = await fetch(new URL('upload', location.href), {method: 'POST', body: selected, headers: {
      'Content-Type': 'application/octet-stream', 'X-Client-Sent-Utc': new Date().toISOString(),
      'X-Capture-Started-Utc': captureStarted, 'X-Capture-Ended-Utc': captureEnded,
      'X-Preview-Confirmed': String($('confirmed').checked), 'X-Heard-Noise': $('heard').value, 'X-Note': encodeURIComponent($('note').value)
    }});
    if (!response.ok) throw new Error(response.status === 413 ? 'TooLarge' : response.status === 415 ? 'Format' : 'Receive');
    const result = await response.json();
    if (!result.received) throw new Error('Receive');
    setStatus('PCへ送信しました。PCアプリの受信一覧で確認できます。スマホの元ファイルは消しません。');
  } catch (error) {
    setStatus(error.message === 'Format' ? 'この形式を受け取れません。音声・動画ファイルを選び直してください。' : '送信できませんでした。PCの受付、同じWi-Fi、ファイアウォール、QRの期限を確認して再送してください。元の記録は残っています。');
    $('send').disabled = false;
  }
});
window.addEventListener('pagehide', () => { if (mediaStream) mediaStream.getTracks().forEach(track => track.stop()); });
