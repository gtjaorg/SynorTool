import {useEffect,useRef,useState} from 'react';

type Config = {BalanceUrl:string;BalancePath:string;BalanceCurrencyPath:string;BaseUrl:string;Model:string;ApiKey:string;SystemPrompt:string;ReasoningControl:boolean;ContextCompressionBytes:number;WorkingDirectory:string;UserAgent:string;TranslationEngine:'model'|'apple';Cumulative?:{InputTokens:number;OutputTokens:number;TotalTokens:number;CachedTokens:number}};

/**
 * 聊天页只保留入口按钮。配置改为独立原生窗口，避免主页面跳转丢对话，也不再被弹层遮住聊天。
 */
export function SettingsEntry() {
  return <button type="button" className="settings-entry" onClick={()=>window.webkit?.messageHandlers.synor.postMessage({type:'open-settings'})}>配置</button>;
}

/**
 * 独立配置窗口（settings.html）使用的整页表单；背景保持透明，透出原生玻璃。
 */
export function SettingsPage() {
  const requestId=useRef('');
  const modelsRequestId=useRef('');
  const balanceRequestId=useRef('');
  const [loadingBalance,setLoadingBalance]=useState(false);
  const [balance,setBalance]=useState('');
  const [balanceError,setBalanceError]=useState('');
  const [form,setForm]=useState<Config>({BalanceUrl:'',BalancePath:'balance_infos[0].total_balance',BalanceCurrencyPath:'balance_infos[0].currency',BaseUrl:'',Model:'',ApiKey:'',SystemPrompt:'',ReasoningControl:true,ContextCompressionBytes:131072,WorkingDirectory:'',UserAgent:'',TranslationEngine:'model'});
  const [models,setModels]=useState<string[]>([]);
  const [loadingModels,setLoadingModels]=useState(false);
  const [defaultPrompt,setDefaultPrompt]=useState('');
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState('');
  const [tab,setTab]=useState<'connection'|'context'|'prompt'>('connection');
  const saving=useRef(false);
  const close=()=>window.webkit?.messageHandlers.synor.postMessage({type:'close'});
  useEffect(()=>{
    const receive=(event:Event)=>{
      const result=(event as CustomEvent).detail;
      if(result.id===balanceRequestId.current){
        balanceRequestId.current='';setLoadingBalance(false);
        if(result.error)setBalanceError(result.error);
        else setBalance(`${result.balance} ${result.currency}`);
        return;
      }
      // 模型列表请求与配置读写共用同一个事件通道，按标识分别处理。
      if(result.id===modelsRequestId.current&&(result.models||result.error)){
        modelsRequestId.current='';setLoadingModels(false);
        if(Array.isArray(result.models)){setModels(result.models as string[]);setError('');}
        else setError(result.error);
        return;
      }
      if(result.id!==requestId.current)return;
      setBusy(false);
      if(result.error){setError(result.error);return;}
      if(result.settings){
        setForm(result.settings);
        if(typeof result.defaultSystemPrompt==='string')setDefaultPrompt(result.defaultSystemPrompt);
        // 只有保存成功才关闭窗口；单纯读取配置时保持打开。
        if(saving.current){saving.current=false;close();}
      }
    };
    window.addEventListener('synor-chat',receive);
    requestId.current=crypto.randomUUID();setBusy(true);
    window.webkit?.messageHandlers.synor.postMessage({type:'settings-load',id:requestId.current});
    return ()=>window.removeEventListener('synor-chat',receive);
  },[]);
  useEffect(()=>{
    balanceRequestId.current='';setLoadingBalance(false);setBalance('');setBalanceError('');
  },[form.BalanceUrl,form.BalancePath,form.BalanceCurrencyPath,form.ApiKey,form.UserAgent,form.BaseUrl]);
  const fetchModels=()=>{
    if(!form.BaseUrl.trim()){setError('请先填写 API 基础地址，再获取模型列表。');return;}
    setError('');setLoadingModels(true);
    modelsRequestId.current=crypto.randomUUID();
    window.webkit?.messageHandlers.synor.postMessage({type:'models-load',id:modelsRequestId.current,baseUrl:form.BaseUrl,apiKey:form.ApiKey,userAgent:form.UserAgent});
  };
  return <section className="settings-panel settings-standalone" aria-label="AI 配置">
    <form onSubmit={event=>{
      event.preventDefault();event.stopPropagation();setError('');setBusy(true);saving.current=true;
      requestId.current=crypto.randomUUID();
      window.webkit?.messageHandlers.synor.postMessage({type:'settings-save',id:requestId.current,settings:form});
    }}>
      <p className="settings-description">使用 OpenAI Responses 接口，保存后对下一次提问生效。</p>
      <nav className="settings-tabs" aria-label="设置分类">{[['connection','连接与模型'],['context','上下文与生成'],['prompt','工具与提示词']].map(([id,label])=><button type="button" className={tab===id?'active':''} onClick={()=>setTab(id as typeof tab)} key={id}>{label}</button>)}</nav>
      {tab==='connection' && <div>
      <label>API 基础地址<input required type="url" value={form.BaseUrl} placeholder="http://127.0.0.1:1234/v1" onChange={e=>{setForm({...form,BaseUrl:e.target.value});setModels([]);}}/><small>包含 /v1 等版本路径，不包含具体接口路径；远程服务使用 HTTPS。</small></label>
      <div className="settings-field">
        <label htmlFor="settings-model">模型名称</label>
        <span className="settings-model">
          <input id="settings-model" required list="settings-model-options" value={form.Model} placeholder="google/gemma-4-e4b" onChange={e=>setForm({...form,Model:e.target.value})}/>
          <button type="button" disabled={loadingModels||busy} onClick={fetchModels}>{loadingModels?'获取中…':'获取列表'}</button>
        </span>
        <datalist id="settings-model-options">{models.map(model=><option key={model} value={model}/>)}</datalist>
        <small>{models.length?`已从服务读取 ${models.length} 个模型，可下拉选择或继续手动输入。`:'“获取列表”会按当前基础地址与 API Key 请求服务端的 /models；也可直接手动输入模型名。'}</small>
      </div>
      <label>API Key<input type="password" autoComplete="off" value={form.ApiKey} placeholder="本地无认证服务可留空" onChange={e=>setForm({...form,ApiKey:e.target.value})}/><small>保存在 ~/Library/Application Support/Synor/settings.json（含 API Key，文件权限仅当前用户可读写）；清空并保存可移除密钥。</small></label>
      <label>User-Agent<input value={form.UserAgent} placeholder="pi (macOS 26.6.1; arm64)" onChange={e=>setForm({...form,UserAgent:e.target.value})}/><small>部分中转服务（如 agentrouter）只放行已知客户端标识；留空使用与 Pi 一致的默认值。</small></label>
      <fieldset>
        <legend>余额查询</legend>
        <label>查询地址<input type="url" value={form.BalanceUrl} placeholder="https://api.deepseek.com/user/balance" onChange={e=>setForm({...form,BalanceUrl:e.target.value})}/><small>可选，填写完整 HTTPS 地址。点击查询时使用当前 API Key 发送 GET 请求，请确认地址属于该密钥的服务商。</small></label>
        <label>余额字段路径<input value={form.BalancePath} placeholder="balance_infos[0].total_balance" onChange={e=>setForm({...form,BalancePath:e.target.value})}/></label>
        <label>币种字段路径<input value={form.BalanceCurrencyPath} placeholder="balance_infos[0].currency" onChange={e=>setForm({...form,BalanceCurrencyPath:e.target.value})}/><small>支持 data.balance 等对象路径与 [0] 数组下标；默认字段路径适用于 DeepSeek。</small></label>
        <button type="button" disabled={busy||loadingBalance||!form.BalanceUrl.trim()||!form.BalancePath.trim()||!form.BalanceCurrencyPath.trim()} onClick={()=>{
          setBalance('');setBalanceError('');setLoadingBalance(true);balanceRequestId.current=crypto.randomUUID();
          window.webkit?.messageHandlers.synor.postMessage({type:'balance-load',id:balanceRequestId.current,settings:form});
        }}>{loadingBalance?'查询中…':'查询余额'}</button>
        {balance && <p role="status">余额：{balance}</p>}
        {balanceError && <p role="alert" className="settings-error">{balanceError}</p>}
      </fieldset>
      </div>}
      {tab==='context' && <div>
      <label>工作目录<input required value={form.WorkingDirectory} placeholder="例如 ~/Desktop/MyProject" onChange={e=>setForm({...form,WorkingDirectory:e.target.value})}/><small>工具以当前用户权限自动执行，此目录用于解析相对路径，不限制访问范围。</small></label>
      <label>上下文压缩大小（KB）<input required type="number" min="16" max="2048" value={Math.round(form.ContextCompressionBytes/1024)} onChange={e=>setForm({...form,ContextCompressionBytes:Math.round(Number(e.target.value)*1024)})}/><small>超过此大小会自动移除最早的对话内容，默认 128 KB。</small></label>
      <label>翻译引擎<select value={form.TranslationEngine} onChange={e=>setForm({...form,TranslationEngine:e.target.value as Config['TranslationEngine']})}><option value="model">当前模型服务</option><option value="apple">Apple 本地翻译</option></select><small>Apple 本地翻译在本机完成，首次使用需按系统提示下载语言包；失败时自动改用当前模型服务。</small></label>
      <label className="settings-check"><input type="checkbox" checked={form.ReasoningControl} onChange={e=>setForm({...form,ReasoningControl:e.target.checked})}/>发送思考控制参数</label>
      </div>}
      {tab==='prompt' && <div>
      <label>附加系统提示词<textarea rows={5} value={form.SystemPrompt} placeholder="留空表示只用内置提示词；此处可追加项目要求，例如：请用中文回答。" onChange={e=>setForm({...form,SystemPrompt:e.target.value})}/><small>这里填写的内容会追加在下面那段内置提示词之后。</small></label>
      {defaultPrompt && <div className="settings-prompt-preview"><span>内置默认提示词（始终发送，只读）</span><pre>{defaultPrompt}</pre></div>}
      <p className="settings-description">服务不支持 reasoning_effort 时关闭此项，思考行为将由服务端决定。</p>
      </div>}
      {error && <p role="alert" className="settings-error">{error}</p>}
      <div className="settings-actions"><button type="button" onClick={close}>取消</button><button className="settings-save" type="submit" disabled={busy}>{busy?'处理中…':'保存配置'}</button></div>
    </form>
  </section>;
}
