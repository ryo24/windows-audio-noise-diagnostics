'use strict';
const pairUrl = new URL('./', location.href).href;
const pairLink = document.getElementById('pair-link');
pairLink.textContent = pairUrl;
pairLink.href = pairUrl;
new QRCode(document.getElementById('qrcode'), {text: pairUrl, width: 280, height: 280, correctLevel: QRCode.CorrectLevel.M});
