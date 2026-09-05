import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const luciRoot = path.join(root, 'build/ui-verification/luci/modules/luci-base/htdocs/luci-static/resources');
const themeRoot = path.join(root, 'build/ui-verification/luci/themes/luci-theme-bootstrap/htdocs/luci-static');
const viewFile = path.join(root, 'htdocs/luci-static/resources/view/feiyoung/general.js');
let currentClient = 'pc';
let currentDiagnostics = '0';

const mime = { '.js': 'application/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml' };
const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/luci-static/bootstrap/cascade.css"><link rel="stylesheet" href="/luci-static/bootstrap/mobile.css"><script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script></head><body><main id="maincontent"><div id="view"></div></main><script>
window.L = new LuCI({base_url:'/luci-static/resources',scriptname:'/cgi-bin/luci',ubuspath:'/cgi-bin/luci/admin/ubus',token:'test-token',pollinterval:300});
window.addEventListener('load', async () => { try { const view = await L.require('view.feiyoung.general'); const node = await view.render(await view.load()); document.querySelector('#view').appendChild(node); document.querySelector('#view').appendChild(view.addFooter()); } catch(e) { document.body.dataset.error = String(e.stack || e); console.error(e); } });
</script></body></html>`;

function reply(res, value, type = 'application/json') { res.writeHead(200, { 'Content-Type': type }); res.end(type === 'application/json' ? JSON.stringify(value) : value); }
function rpcResult(req) {
  if (req.method !== 'POST') return { jsonrpc: '2.0', id: 1, result: [0, {}] };
  return req.body.then(raw => {
    let calls; try { calls = JSON.parse(raw); } catch { calls = []; }
    const list = Array.isArray(calls) ? calls : [calls];
    console.log('RPC', list.map(c => ({ object: c.object, method: c.method, params: c.params })));
    return list.map(call => {
      const p = call.params || [];
      const object = call.method === 'call' ? p[1] : call.object;
      const method = call.method === 'call' ? p[2] : call.method;
      const params = call.method === 'call' ? p[3] : p;
      if (method === 'list') return { jsonrpc:'2.0', id:call.id, result:[0, {luci:{setInitAction:true}, file:{read:true}, uci:{get:true,set:true,apply:true}}] };
      if (object === 'session' && method === 'access') return { jsonrpc:'2.0', id:call.id, result:[0,{access:true}] };
      if (object === 'uci' && method === 'set' && params?.config === 'feiyoung' && params.section === 'general') { currentClient = params.values?.client_type || currentClient; currentDiagnostics = params.values?.diagnostics || currentDiagnostics; return { jsonrpc:'2.0', id:call.id, result:[0,{}] }; }
      if (object === 'uci' && method === 'apply' && typeof params?.timeout === 'number' && typeof params?.rollback === 'boolean') return { jsonrpc:'2.0', id:call.id, result:[0,{}] };
      if (object === 'uci' && method === 'get' && params?.config === 'feiyoung') return { jsonrpc:'2.0', id:call.id, result:[0,{values:{general:{'.name':'general','.type':'global','.index':0,enabled:'1',username:'13800138000',client_type:currentClient,diagnostics:currentDiagnostics,password:'123456'}}}] };
      if (object === 'file' && method === 'read' && params?.path === '/tmp/feiyoung_status') return { jsonrpc:'2.0', id:call.id, result:[0,{data:'运行中'}] };
      if (object === 'luci' && method === 'getFeatures') return { jsonrpc:'2.0', id:call.id, result:[0,{}] };
      return { jsonrpc:'2.0', id:call.id, error:{code:-32601,message:'unsupported mock RPC'} };
    });
  });
}
const server = http.createServer(async (req, res) => {
  const chunks=[]; req.on('data', c=>chunks.push(c)); await new Promise(resolve=>req.on('end',resolve)); req.body=Promise.resolve(Buffer.concat(chunks).toString());
  if (req.url === '/' || req.url?.startsWith('/index.html')) return reply(res, html, 'text/html');
  if (req.url?.startsWith('/cgi-bin/luci/admin/ubus')) return reply(res, await rpcResult(req));
  let file;
  if (req.url === '/luci-static/resources/view/feiyoung/general.js') file = viewFile;
  else if (req.url?.startsWith('/luci-static/bootstrap/')) file = path.join(themeRoot, req.url.replace('/luci-static/', ''));
  else if (req.url?.startsWith('/luci-static/resources/')) file = path.join(luciRoot, req.url.replace('/luci-static/resources/', ''));
  if (!file || !fs.existsSync(file)) return res.writeHead(404).end();
  reply(res, fs.readFileSync(file), mime[path.extname(file)] || 'application/octet-stream');
});
server.listen(0, '127.0.0.1', () => console.log(`http://127.0.0.1:${server.address().port}`));
