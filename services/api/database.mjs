import { DatabaseSync } from 'node:sqlite';
import { fail, validateRecord } from './records.mjs';
export function openDatabase(path) {
  const db=new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS records (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
      actor TEXT NOT NULL, url TEXT NOT NULL, operation TEXT NOT NULL,
      target TEXT NOT NULL, withdrawn TEXT NOT NULL, received_at TEXT NOT NULL,
      json TEXT NOT NULL, payload TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS source_records ON records(url,sequence);
    CREATE INDEX IF NOT EXISTS actor_received ON records(actor,received_at);
    CREATE INDEX IF NOT EXISTS received_records ON records(received_at);
    CREATE UNIQUE INDEX IF NOT EXISTS one_withdrawal ON records(withdrawn) WHERE operation='withdrawal';
    CREATE TRIGGER IF NOT EXISTS immutable_update BEFORE UPDATE ON records BEGIN SELECT RAISE(ABORT,'immutable'); END;
    CREATE TRIGGER IF NOT EXISTS immutable_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'immutable'); END;
    PRAGMA user_version=1;`);
  return db;
}
export function publish(db, record, {actorDaily=200, globalDaily=5000, maxRecords=100000, blockedActors=[]}={}) {
  const r=validateRecord(record);
  if(blockedActors.includes(r.actorId) && r.operation!=='withdrawal') fail('actor_blocked',403);
  db.exec('BEGIN IMMEDIATE');
  try {
    const prior=db.prepare('SELECT * FROM records WHERE id=?').get(r.id);
    if(prior) {
      if(prior.payload!==r.signedPayload) fail('id_conflict',409);
      db.exec('COMMIT'); return {id:r.id,sequence:prior.sequence,receivedAt:prior.received_at,duplicate:true};
    }
    if(r.operation==='withdrawal') {
      const original=db.prepare("SELECT * FROM records WHERE id=? AND operation='record'").get(r.withdrawnRecordId);
      if(!original) fail('original_not_published',409);
      if(original.actor!==r.actorId || original.url!==r.url) fail('withdrawal_not_owner',403);
      const priorWithdrawal=db.prepare("SELECT * FROM records WHERE withdrawn=? AND operation='withdrawal'").get(r.withdrawnRecordId);
      if(priorWithdrawal) { db.exec('COMMIT'); return {id:priorWithdrawal.id,sequence:priorWithdrawal.sequence,receivedAt:priorWithdrawal.received_at,duplicate:true}; }
    } else {
      if(r.targetId && !db.prepare("SELECT id FROM records WHERE id=? AND operation='record'").get(r.targetId)) fail('target_not_published',409);
      const start=new Date().toISOString().slice(0,10)+'T00:00:00.000Z';
      const count=db.prepare("SELECT COUNT(*) n FROM records WHERE operation='record'").get().n;
      if(count>=maxRecords) fail('capacity_reached',503);
      if(db.prepare("SELECT COUNT(*) n FROM records WHERE actor=? AND received_at>=? AND operation='record'").get(r.actorId,start).n>=actorDaily) fail('actor_daily_limit',429);
      if(db.prepare("SELECT COUNT(*) n FROM records WHERE received_at>=? AND operation='record'").get(start).n>=globalDaily) fail('daily_capacity_reached',429);
    }
    const receivedAt=new Date().toISOString();
    const result=db.prepare('INSERT INTO records(id,actor,url,operation,target,withdrawn,received_at,json,payload) VALUES(?,?,?,?,?,?,?,?,?)')
      .run(r.id,r.actorId,r.url,r.operation,r.targetId,r.withdrawnRecordId,receivedAt,JSON.stringify(r),r.signedPayload);
    db.exec('COMMIT'); return {id:r.id,sequence:Number(result.lastInsertRowid),receivedAt,duplicate:false};
  } catch(e){db.exec('ROLLBACK');throw e;}
}
export function listPage(db,url,before=Number.MAX_SAFE_INTEGER,limit=25) {
  const rows=db.prepare(`SELECT r.* FROM records r WHERE r.url=? AND r.operation='record' AND r.sequence<?
    AND NOT EXISTS(SELECT 1 FROM records w WHERE w.operation='withdrawal' AND w.withdrawn=r.id)
    ORDER BY r.sequence DESC LIMIT ?`).all(url,before,limit+1);
  const page=rows.slice(0,limit);
  return {records:page.map(row=>JSON.parse(row.json)), nextBefore:rows.length>limit?page.at(-1).sequence:null, sourceUrl:url};
}
