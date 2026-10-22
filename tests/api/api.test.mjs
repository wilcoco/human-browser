import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync,randomUUID,sign} from 'node:crypto';
import {mkdtempSync,rmSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {hash,validateRecord,canonical} from '../../services/api/records.mjs';
import {openDatabase,publish,listPage} from '../../services/api/database.mjs';
import {createApp} from '../../services/api/server.mjs';
export function identity(){return generateKeyPairSync('ec',{namedCurve:'prime256v1'});}
export function record(key=identity(),changes={}) {
 const publicKey=key.publicKey.export({format:'der',type:'spki'});
 const r={url:'https://example.com/article?a=1',title:'시험',quote:'사람의 판단 💬 / "검토"',capturedAt:new Date().toISOString(),kind:'comment',text:'합성 테스트 기록',targetId:'',criterion:'',value:'',disposition:'',relation:'',id:randomUUID(),protocolVersion:'android-local-alpha/1',canonicalization:'android-fixed-string-json/1',algorithm:'SHA256withECDSA/P-256',actorId:'actor:'+hash(publicKey),publicKey:publicKey.toString('base64'),createdAt:new Date().toISOString(),operation:'record',withdrawnRecordId:'',...changes};
 r.quoteDigest=hash(r.quote);
 r.signedPayload=canonical(r);
 r.signature=sign('sha256',Buffer.from(r.signedPayload),key.privateKey).toString('base64');return r;
}
const memory=()=>openDatabase(':memory:');
function withdrawal(key,r){return record(key,{...Object.fromEntries(['url','title','quote','capturedAt','kind'].map(k=>[k,r[k]])),operation:'withdrawal',withdrawnRecordId:r.id,text:''});}
test('valid Unicode and signature roundtrip',()=>{assert.equal(validateRecord(record()).kind,'comment');});
test('tampered envelope, payload, signature and actor rejected',()=>{
 for(const field of ['text','signedPayload','signature','actorId','quoteDigest']){const r=record();r[field]+='x';assert.throws(()=>validateRecord(r));}
});
test('invalid kinds, fields, URL, sizes and operation rejected',()=>{
 for(const change of [{kind:'bot'},{extra:'x'},{url:'file:///secret'},{url:'https://u:p@example.com'},{text:'a'.repeat(32769)},{operation:'erase'},{text:''},{targetId:'fake'},{quote:'\ud800'},{kind:'evaluation'},{kind:'relation'},{kind:'decision'}]) assert.throws(()=>validateRecord(record(identity(),change)));
});
test('publication, exact URL scoping and immutable duplicate',()=>{
 const db=memory(),r=record();const a=publish(db,r);assert.equal(a.duplicate,false);assert.equal(publish(db,r).duplicate,true);
 assert.equal(listPage(db,r.url).records.length,1);assert.equal(listPage(db,r.url+'&b=2').records.length,0);
 assert.throws(()=>publish(db,record(identity(),{id:r.id})),/id_conflict/);
 assert.throws(()=>db.exec("UPDATE records SET url='x'"),/immutable/);assert.throws(()=>db.exec('DELETE FROM records'),/immutable/);db.close();
});
test('cross-device evaluation and reply require exact published target',()=>{
 const db=memory(),r=record();publish(db,r);
 const e=record(identity(),{kind:'evaluation',targetId:r.id,criterion:'근거',value:'확인 필요'});publish(db,e);
 assert.equal(listPage(db,r.url).records[0].targetId,r.id);
 assert.throws(()=>publish(db,record(identity(),{kind:'answer',targetId:randomUUID()})),/target_not_published/);db.close();
});
test('owner-only withdrawal preserves history and dependent evaluation',()=>{
 const db=memory(),key=identity(),r=record(key);publish(db,r);
 const e=record(identity(),{kind:'evaluation',targetId:r.id,criterion:'도움',value:'유용'});publish(db,e);
 assert.throws(()=>publish(db,withdrawal(identity(),r)),/withdrawal_not_owner/);
 assert.throws(()=>publish(db,record(key,{...withdrawal(key,r),url:'https://example.com/wrong'})),/payload_mismatch|noncanonical_payload|invalid_signature|withdrawal_not_owner/);
 publish(db,withdrawal(key,r));assert.equal(listPage(db,r.url).records.length,1);
 assert.equal(publish(db,r).duplicate,true);assert.equal(listPage(db,r.url).records[0].id,e.id);
 assert.equal(publish(db,withdrawal(key,r)).duplicate,true);assert.equal(db.prepare('SELECT COUNT(*) n FROM records').get().n,3);db.close();
});
test('quotas persist, duplicate and withdrawal allowed at capacity',()=>{
 const db=memory(),key=identity(),r=record(key);publish(db,r,{actorDaily:1});
 assert.throws(()=>publish(db,record(key),{actorDaily:1}),/actor_daily_limit/);
 assert.throws(()=>publish(db,record(),{globalDaily:1}),/daily_capacity_reached/);
 assert.throws(()=>publish(db,record(),{maxRecords:1}),/capacity_reached/);
 assert.equal(publish(db,r,{maxRecords:0}).duplicate,true);
 publish(db,withdrawal(key,r),{actorDaily:0,maxRecords:0});db.close();
});
test('stable pagination and database reopen',()=>{
 const dir=mkdtempSync(join(tmpdir(),'human-api-')),path=join(dir,'test.sqlite3');let db=openDatabase(path);
 for(let i=0;i<30;i++)publish(db,record());const first=listPage(db,'https://example.com/article?a=1');assert.equal(first.records.length,25);
 db.close();db=openDatabase(path);const second=listPage(db,first.sourceUrl,first.nextBefore);assert.equal(second.records.length,5);
 assert.equal(new Set([...first.records,...second.records].map(r=>r.id)).size,30);assert.equal(second.nextBefore,null);db.close();rmSync(dir,{recursive:true});
});
test('HTTP validation, cross-client publication, retrieval and withdrawal',async()=>{
 const db=memory(),server=createApp({db});await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port;
 try{
 const post=r=>fetch(base+'/v1/records',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(r)});
 assert.equal((await fetch(base+'/healthz')).status,200);assert.equal((await fetch(base+'/v1/records')).status,400);
 assert.equal((await fetch(base+'/v1/records',{method:'POST',body:'hi'})).status,415);
 const key=identity(),r=record(key);assert.equal((await post(r)).status,201);assert.equal((await post(r)).status,200);
 assert.equal((await post({...r,text:'changed'})).status,400);
 const page=base+'/v1/records?url='+encodeURIComponent(r.url);assert.equal((await(await fetch(page)).json()).records[0].text,r.text);
 assert.equal((await fetch(page+'&before=no')).status,400);
 assert.equal((await post(withdrawal(identity(),r))).status,403);
 assert.equal((await post(withdrawal(key,r))).status,201);assert.equal((await(await fetch(page)).json()).records.length,0);
 assert.equal((await fetch(base+'/unknown')).status,404);
 }finally{await new Promise(r=>server.close(r));db.close();}
});

test('real AndroidKeyStore fixture is accepted and hidden after owner withdrawal',()=>{
 const archive=JSON.parse(readFileSync(new URL('./android-fixture.json',import.meta.url)));const db=memory();
 for(const event of archive.records) publish(db,event);
 assert.equal(listPage(db,archive.records[0].url).records.length,0);db.close();
});
test('a valid signature with noncanonical JSON cannot poison Android feed',()=>{
 const key=identity(),r=record(key);r.signedPayload=JSON.stringify(JSON.parse(r.signedPayload));
 r.signature=sign('sha256',Buffer.from(r.signedPayload),key.privateKey).toString('base64');
 assert.throws(()=>validateRecord(r),/noncanonical_payload/);
});

test('one URL shares each author’s complete judgment while another URL remains separate',async()=>{
 const db=memory(),server=createApp({db});await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port;
 const url='https://example.com/shared-judgment',other='https://example.com/different-judgment';
 const alice=identity(),bob=identity();
 const judgment=record(alice,{url,kind:'decision',title:'자료 검토',quote:'판단의 근거 문장',text:'추가 근거를 기다립니다.',disposition:'보류'});
 const question=record(bob,{url,kind:'question',text:'어떤 근거가 더 필요한가요?'});
 try {
  for(const r of [judgment,question,record(alice,{url:other,text:'다른 페이지의 판단'})]) {
   const response=await fetch(base+'/v1/records',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(r)});assert.equal(response.status,201);
  }
  // A separate reader needs only the shared source URL, not the author’s local files or key.
  const response=await fetch(base+'/v1/records?url='+encodeURIComponent(url));const body=await response.json();
  assert.equal(body.records.length,2);assert.equal(new Set(body.records.map(r=>r.actorId)).size,2);
  const seen=body.records.find(r=>r.id===judgment.id);
  for(const k of ['text','quote','disposition','url','actorId','signature'])assert.equal(seen[k],judgment[k]);
  assert.ok(body.records.every(r=>r.url===url));
 } finally {await new Promise(r=>server.close(r));db.close();}
});
