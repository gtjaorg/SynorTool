import {useEffect,useRef,useState} from 'react';

export function Translation() {
  const requestId=useRef('');
  const [source,setSource]=useState('');
  const [target,setTarget]=useState('简体中文');
  const [result,setResult]=useState('');
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState('');
  const [copied,setCopied]=useState(false);
  const answer=useRef('');
  useEffect(()=>{
    const receive=(event:Event)=>{
      const payload=(event as CustomEvent).detail;
      if(payload.type==='open-translation'){
        if(requestId.current)window.webkit?.messageHandlers.synor.postMessage({type:'cancel',id:requestId.current});
        const text=payload.text ?? '';
        const nextTarget=/\p{Script=Han}/u.test(text) ? 'English' : '简体中文';
        requestId.current='';setBusy(false);setSource(text);setTarget(nextTarget);setResult('');setError('');setCopied(false);
        if(text.trim()){
          answer.current='';setBusy(true);requestId.current=crypto.randomUUID();
          window.webkit?.messageHandlers.synor.postMessage({type:'translate',id:requestId.current,text,target:nextTarget});
        }
        return;
      }
      if(!requestId.current || payload.id!==requestId.current)return;
      if(payload.text){answer.current+=payload.text;setResult(answer.current);}
      if(payload.error || payload.done){
        setBusy(false);requestId.current='';
        if(payload.error)setError(payload.error);
        else if(!answer.current)setError('模型没有返回译文，请重试。');
        // Keep the translated result in the translation window; do not write it to Synor's composer.
      }
    };
    window.addEventListener('synor-chat',receive);
    window.webkit?.messageHandlers.synor.postMessage({type:'ready'});
    return ()=>{
      window.removeEventListener('synor-chat',receive);
      if(requestId.current)window.webkit?.messageHandlers.synor.postMessage({type:'cancel',id:requestId.current});
    };
  },[]);
  return <section className="settings-panel translation-panel translation-standalone">
      <p className="settings-description">自动识别原文语言，使用配置中选择的翻译引擎。</p>
      <label>目标语言<select value={target} disabled={busy} onChange={e=>{setTarget(e.target.value);setResult('');setCopied(false);}}>{['简体中文','繁體中文','English','日本語','한국어','Français','Deutsch'].map(language=><option key={language}>{language}</option>)}</select></label>
      <label>原文<textarea rows={5} value={source} disabled={busy} placeholder="输入或粘贴需要翻译的文字…" onChange={e=>{setSource(e.target.value);setResult('');setCopied(false);}}/></label>
      <div className="translation-actions"><span className="settings-description">译文不会写入聊天记录。</span>{busy ? <button type="button" onClick={()=>{
        window.webkit?.messageHandlers.synor.postMessage({type:'cancel',id:requestId.current});requestId.current='';setBusy(false);
      }}>停止翻译</button> : <button type="button" className="settings-save" disabled={!source.trim()} onClick={()=>{
        setError('');setCopied(false);setResult('');answer.current='';setBusy(true);requestId.current=crypto.randomUUID();
        window.webkit?.messageHandlers.synor.postMessage({type:'translate',id:requestId.current,text:source,target});
      }}>开始翻译</button>}</div>
      <section className="translation-output"><div className="settings-heading"><h3>译文</h3><button type="button" disabled={!result || busy} onClick={()=>{window.webkit?.messageHandlers.synor.postMessage({type:'copy',text:result});setCopied(true);}}>{copied?'已复制 ✓':'复制译文'}</button></div><div className="translation-result">{result || (busy?'正在翻译…':'译文将在这里显示')}</div></section>
      {error && <p role="alert" className="settings-error">{error}</p>}
    </section>;
}
