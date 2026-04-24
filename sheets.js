// api/sheets.js — Vercel Serverless Function
const https = require('https');

const APPS_SCRIPT_URL = 'https://script.google.com/macros/s/AKfycbzrXmjKr_Bp1JiqCtjB3Vu7yHnG2Clh_iMj7CLZt9dGslcBKSslC5sH6OKEQQSYIEwetw/exec';

function httpsGet(url, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    if (redirectCount > 5) return reject(new Error('Demasiados redirects'));
    https.get(url, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302 || res.statusCode === 303) {
        const location = res.headers.location;
        if (!location) return reject(new Error('Redirect sin location'));
        return httpsGet(location, redirectCount + 1).then(resolve).catch(reject);
      }
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

module.exports = async function(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'Method Not Allowed' });

  try {
    const payload = req.body;
    const params  = encodeURIComponent(JSON.stringify(payload));
    const url     = `${APPS_SCRIPT_URL}?data=${params}`;
    const text    = await httpsGet(url);
    res.setHeader('Content-Type', 'application/json');
    res.status(200).send(text);
  } catch(err) {
    res.status(500).json({ ok: false, error: err.message });
  }
};
