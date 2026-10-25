var state = {toolDetail:{useMemories:false,memories:[]}};
// Local recommendation context only. Reading preferences never starts a task or calls a service.
const homeHookMemoryApps={
 meituan:/美团|meituan/i,
 ctrip:/携程|ctrip|trip\.com/i,
 wechat:/微信|朋友圈|wechat|weixin|\bpyq\b/i,
 xiaohongshu:/小红书|\bxhs\b|xiaohongshu|rednote/i,
 clock:/闹钟|时钟|叫醒|响铃|起床|倒计时|计时器/i
};
const homeHookMemoryTopics={
 meal:/外卖|饮食|吃饭|饭菜|餐食|菜系|口味|忌口|过敏|清淡|重口|少盐|低盐|少油|低脂|素食|香菜|花生|海鲜|辣|甜食|午餐|晚餐|早餐/,
 drink:/咖啡|拿铁|美式|卡布奇诺|浓缩|饮品|奶茶|糖度|少糖|无糖|半糖|去冰|少冰|热饮|燕麦奶|乳糖/,
 groceries:/食材|买菜|蔬菜|水果|冰箱|鸡蛋|鲜奶|粮油|有机|冷冻/,
 flight:/机票|航班|飞行|直飞|转机|红眼|机场|舱位|经济舱|商务舱|托运行李|航空公司|航司/,
 hotel:/酒店|旅馆|民宿|住宿|房型|大床|双床|无烟房|含早|退房|隔音/,
 train:/高铁|火车|动车|车次|二等座|一等座|商务座|卧铺|车厢|席别/,
 travel:/旅行|旅游|攻略|行程|景点|徒步|海边|博物馆|人文|自然风景/,
 like:/点赞|点个赞|点了赞|按赞/,
 chatSearch:/聊天记录|搜索消息|查找消息|找聊天|聊天搜索|关键词/,
 fileSearch:/聊天文件|微信文件|文件查找|文件名|附件/,
 summary:/未读|消息摘要|消息整理|提炼|摘要|总结/,
 writing:/回复|评论|文案|写作|笔记风格|表达|语气|说话|简洁|简短|口语|自然一点|商务腔|表情包|emoji/i,
 product:/商品|产品|型号|购物|测评|使用体验|性价比|种草/,
 outfit:/穿搭|通勤|衣服|服装|显瘦|配色|运动风|极简风/,
 collect:/收藏|合集|收藏夹|保存笔记/,
 alarm:/闹钟|叫醒|响铃|起床/,
 timer:/倒计时|计时器|番茄钟|专注时间|专注时长/
};
const homeHookMemoryProfiles={
 meituan_takeout:['meal'],meituan_coffee:['drink'],meituan_groceries:['groceries','meal'],
 meituan_compare:['meal'],meituan_track:[],meituan_reorder:['meal'],
 ctrip_flight:['flight'],ctrip_roundtrip:['flight'],ctrip_direct:['flight'],
 ctrip_hotel:['hotel'],ctrip_train:['train'],ctrip_orders:[],
 wechat_like:['like'],wechat_comment:['writing'],
 'wechat_find-chat':['chatSearch'],'wechat_find-file':['fileSearch'],
 wechat_unread:['summary'],wechat_reply:['writing'],
 xiaohongshu_travel:['travel'],xiaohongshu_food:['meal'],xiaohongshu_review:['product'],
 xiaohongshu_outfit:['outfit'],xiaohongshu_save:['collect'],xiaohongshu_draft:['writing'],
 clock_alarm:['alarm'],clock_weekday:['alarm'],clock_edit:['alarm'],clock_disable:[],clock_list:[],clock_timer:['timer']
};
function homeHookMemoryHash(text){
 let hash=2166136261;
 for(let i=0;i<text.length;i++){hash^=text.charCodeAt(i);hash=Math.imul(hash,16777619)}
 return (hash>>>0).toString(36);
}
function homeHookMemoryContext(){
 if(typeof ensureToolDetailState==='function')ensureToolDetailState();
 const detail=state.toolDetail;
 if(!detail||detail.useMemories!==true)return {signature:'off',enabled:false,memories:[],count:0};
 const explicitPreference=/偏好|喜欢|不喜欢|不爱|不吃|不喝|忌口|过敏|习惯|通常|一般会|总是|尽量|希望|我更|我只|我不要|我不想|不要放|不要加/;
 const excludedKind=new Set(['文件','转写','画面']);
 const seen=new Set(),memories=[];
 for(const record of Array.isArray(detail.memories)?detail.memories:[]){
  if(!record||record.enabled!==true||excludedKind.has(record.kind)||typeof record.text!=='string')continue;
  const text=record.text.trim(),title=typeof record.title==='string'?record.title.trim().slice(0,120):'';
  // Long sources remain searchable in the memory page; they are not shortcut preferences.
  if(!text||text.length>600||(record.kind!=='偏好'&&!explicitPreference.test(text)))continue;
  if(record.kind!=='偏好'&&/文件|采集|转写|长任务|AI 整理/.test(String(record.source||'')))continue;
  const id=typeof record.id==='string'&&record.id?record.id:'local-'+homeHookMemoryHash(title+'\n'+text);
  if(seen.has(id))continue;seen.add(id);
  const clauses=text.split(/[\n。；;]+/).map(value=>value.trim()).filter(Boolean);
  memories.push({id,title,text,clauses});
 }
 memories.sort((a,b)=>a.id.localeCompare(b.id));
 const signature='on:'+homeHookMemoryHash(JSON.stringify(memories.map(({id,title,text})=>[id,title,text])));
 return {signature,enabled:true,memories,count:memories.length};
}
function personalizeHomeHook(item,context){
 const original={...item,score:0,memoryIds:[],memoryNotes:[],memoryDetail:''};
 if(!context?.enabled||!Array.isArray(context.memories))return original;
 const topics=homeHookMemoryProfiles[item.id]||[];
 if(!topics.length)return original;
 const matches=[];
 for(const memory of context.memories){
  let score=0;const relevant=[];
  for(const clause of memory.clauses||[]){
   // Do not truncate a sentence before a later exception or negation.
   if(clause.length>180)continue;
   const text=memory.title+' '+clause;
   const apps=Object.keys(homeHookMemoryApps).filter(app=>homeHookMemoryApps[app].test(text));
   // An explicitly named app preference stays with that app. Mixed-app clauses stay out.
   if(apps.length&&(apps.length!==1||apps[0]!==item.appId))continue;
   const overlap=topics.filter(topic=>homeHookMemoryTopics[topic].test(text));
   if(!overlap.length)continue;
   score=Math.max(score,12+overlap.length*4+(apps[0]===item.appId?8:0));
   if(relevant.join('；').length+clause.length+(relevant.length?1:0)<=180)relevant.push(clause);
  }
  if(score&&relevant.length)matches.push({id:memory.id,score,text:relevant.join('；')});
 }
 matches.sort((a,b)=>b.score-a.score||a.id.localeCompare(b.id));
 const selected=matches.slice(0,3);
 if(!selected.length)return original;
 const notes=selected.map(match=>match.text);
 return {...original,
  score:selected.reduce((total,match)=>total+match.score,0),
  memoryIds:selected.map(match=>match.id),memoryNotes:notes,
  memoryDetail:notes.join('；').slice(0,52),
  // Preserve negation and user wording. Never turn a preference into a date, recipient or order.
  prompt:String(item.prompt||'')+'\n\n参考已保存的相关偏好（与本次要求冲突时以本次要求为准；地址、时间和操作对象仍需确认）：\n'+notes.map(note=>'· '+note).join('\n')
 };
}

// Grounded, local context for the home greeting. This never reads calendars,
// weather, files, conversations or an AI service, and never executes a task.
const homeGreetingPeriods=[
 [5,'night','夜深了'],[9,'earlyMorning','早上好'],[11,'morning','上午好'],
 [14,'noon','中午好'],[18,'afternoon','下午好'],[22,'evening','晚上好'],
 [24,'lateNight','夜深了']
];
function homeGreetingDateKey(date){
 return [date.getFullYear(),String(date.getMonth()+1).padStart(2,'0'),String(date.getDate()).padStart(2,'0')].join('-');
}
function homeGreetingContextHash(text){
 let hash=2166136261;
 for(let i=0;i<text.length;i++){hash^=text.charCodeAt(i);hash=Math.imul(hash,16777619)}
 return (hash>>>0).toString(36);
}
function homeGreetingValidDate(value){
 if(value===null||value===undefined||value==='')return null;
 const date=new Date(value);return Number.isFinite(date.getTime())?date:null;
}
function homeGreetingUserRecords(){
 if(typeof ensureToolDetailState==='function')ensureToolDetailState();
 const detail=state.toolDetail;
 if(detail?.useMemories!==true)return {enabled:false,records:[]};
 const records=[],seen=new Set();
 for(const record of Array.isArray(detail.memories)?detail.memories:[]){
  if(!record||record.enabled!==true||!['笔记','偏好'].includes(record.kind))continue;
  if(record.private===true||record.sensitive===true||record.visibility==='private')continue;
  if(typeof record.text!=='string')continue;
  const text=record.text.trim(),title=typeof record.title==='string'?record.title.trim():'';
  const source=typeof record.source==='string'?record.source.trim():'';
  if(!text||text.length>600||title.length>120)continue;
  // A saved assistant answer or imported document is not the user's own plan.
  if(/AI|对话回答|助手|文件|转写|画面|采集|长任务|导入|网页|文章|整理|assistant|transcript|screen/i.test(source))continue;
  if(source&&!/手动|用户|本人|自己/.test(source))continue;
  const id=typeof record.id==='string'&&record.id?record.id:'local-'+homeGreetingContextHash(title+'\n'+text);
  if(seen.has(id))continue;seen.add(id);
  records.push({id,title,text,source,kind:record.kind,createdAt:record.createdAt||null,updatedAt:record.updatedAt||null});
 }
 records.sort((a,b)=>a.id.localeCompare(b.id));
 return {enabled:true,records};
}
function homeGreetingClauses(text,maxLength){
 // Keep commas and their exceptions together. A long clause is omitted rather
 // than clipped before a later negation or condition.
 return text.split(/[\n。；;]+/).map(clause=>clause.trim()).filter(clause=>clause&&clause.length<=maxLength);
}
function homeGreetingDayRelation(text,record,date){
 let remaining=text;const markers=[];
 const add=(match,value)=>{markers.push(value);return ' '.repeat(match.length)};
 remaining=remaining.replace(/\b((?:19|20)\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?/g,(match,year,month,day)=>{
  const candidate=new Date(Number(year),Number(month)-1,Number(day));
  const valid=candidate.getFullYear()===Number(year)&&candidate.getMonth()===Number(month)-1&&candidate.getDate()===Number(day);
  return add(match,{valid,relation:'today',key:valid?homeGreetingDateKey(candidate):null});
 });
 remaining=remaining.replace(/(\d{1,2})\s*月\s*(\d{1,2})\s*日?/g,(match,month,day)=>{
  const created=homeGreetingValidDate(record.createdAt);
  // An old month/day note must not silently become this year's event.
  const candidate=new Date(date.getFullYear(),Number(month)-1,Number(day));
  const valid=!!created&&created.getFullYear()===date.getFullYear()&&candidate.getMonth()===Number(month)-1&&candidate.getDate()===Number(day);
  return add(match,{valid,relation:'today',key:valid?homeGreetingDateKey(candidate):null});
 });
 remaining=remaining.replace(/今天|今日|今晚|今早|今晨|明天|明日|明早|明晚|后天|昨天|昨日/g,match=>{
  const created=homeGreetingValidDate(record.createdAt);
  if(!created)return add(match,{valid:false});
  const delta=/^(明|后)/.test(match)?(match==='后天'?2:1):/^昨/.test(match)?-1:0;
  const candidate=new Date(created.getFullYear(),created.getMonth(),created.getDate()+delta);
  return add(match,{valid:true,relation:'today',key:homeGreetingDateKey(candidate)});
 });
 // A single explicit recurrence is supported. Plain "周六" is not recurring.
 if(/每(?:个)?(?:周|星期|礼拜)[一二三四五六日天1-7]\s*(?:[、和至到-]\s*[一二三四五六日天1-7](?!\d)|[一二三四五六日天])/.test(remaining))return null;
 remaining=remaining.replace(/每(?:个)?(?:周|星期|礼拜)([一二三四五六日天1-7])/g,(match,weekday)=>{
  const number={'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'日':0,'天':0,'1':1,'2':2,'3':3,'4':4,'5':5,'6':6,'7':0}[weekday];
  return add(match,{valid:true,relation:'recurring',matches:number===date.getDay()});
 });
 remaining=remaining.replace(/每(?:个)?周末/g,match=>add(match,{valid:true,relation:'recurring',matches:[0,6].includes(date.getDay())}));
 remaining=remaining.replace(/每天|每日/g,match=>add(match,{valid:true,relation:'recurring',matches:true}));
 if(markers.length!==1||!markers[0].valid)return null;
 const marker=markers[0];
 return marker.relation==='recurring'?(marker.matches?'recurring':null):(marker.key===homeGreetingDateKey(date)?'today':null);
}
function homeGreetingHourNumber(value){
 if(/^\d+$/.test(value))return Number(value);
 const digits={'零':0,'一':1,'二':2,'两':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9};
 if(Object.hasOwn(digits,value))return digits[value];
 if(value==='十')return 10;
 const parts=value.split('十');
 if(parts.length===2&&(!parts[0]||Object.hasOwn(digits,parts[0]))&&(!parts[1]||Object.hasOwn(digits,parts[1])))return (parts[0]?digits[parts[0]]:1)*10+(parts[1]?digits[parts[1]]:0);
 return NaN;
}
function homeGreetingEventTime(text,date){
 const matches=[...text.matchAll(/(凌晨|早上|上午|中午|下午|傍晚|晚上|晚间|夜里)?\s*(\d{1,2}|[一二两三四五六七八九十]{1,3})(?:[:：](\d{2})|点(?:(\d{1,2})分?|(半|一刻|三刻))?)/g)];
 if(matches.length>1)return null;
 if(!matches.length)return {timeMinutes:null,timing:'anytime'};
 const match=matches[0];let hour=homeGreetingHourNumber(match[2]);
 const minute=Number(match[3]||match[4]||(match[5]==='半'?30:match[5]==='一刻'?15:match[5]==='三刻'?45:0));
 if(!Number.isFinite(hour)||hour>23||minute>59)return null;
 // "今晚十二点" crosses the local-day boundary, so do not guess which date
 // the author meant. A bare 12:00 or 上午十二点 keeps its literal noon time.
 if(/傍晚|晚上|晚间|夜里/.test(match[1]||'')&&hour===12)return null;
 if(/下午|傍晚|晚上|晚间/.test(match[1]||'')&&hour<12)hour+=12;
 if(match[1]==='中午'&&hour<11)hour+=12;
 if(match[1]==='凌晨'&&hour===12)hour=0;
 const timeMinutes=hour*60+minute,distance=timeMinutes-(date.getHours()*60+date.getMinutes());
 return {timeMinutes,timing:distance>15?'upcoming':distance< -15?'past':'now'};
}
function homeGreetingPickEvent(records,date){
 const candidates=[];
 const activity=/会议|开会|评审|面试|出差|航班|出发|出行|旅行|去|接机|接人|看牙|复诊|体检|就诊|考试|上课|培训|聚餐|约饭|约会|吃饭|运动|跑步|游泳|打球|健身|提醒|闹钟|起床|提交|交付|截止|还款|缴费|生日|纪念日/;
 const excluded=/取消|改期|延期|推迟|不再|不用|无需|不要|不需要|不打算|没打算|没安排|没有|无安排|不去|不参加|不出发|不开会|不(?:会|是|能|必|准备|安排|计划)|没(?:去|参加|出发|开会|约|订|提交)|未(?:安排|计划|参加|出发|开会|提交|完成)|已经(?:完成|结束|开完|取消|到了|回来)|已(?:经)?(?:完成|结束|取消|改期|开完|交付|提交)|如果|假如|可能|也许|考虑|希望|不一定|待定|是否|[吗？?]/;
 for(const record of records){
  // A following cancellation sentence can invalidate the earlier plan. Until
  // records carry structured event revisions, omit the whole ambiguous note.
  if(excluded.test(record.text+' '+record.title))continue;
  for(const clause of homeGreetingClauses(record.text,110)){
   const datedText=clause+' '+record.title;
   if(!activity.test(clause)||excluded.test(clause)||/喜欢|不喜欢|想(?:去|要|订|约|看)/.test(clause))continue;
   // Prefer a clause's own date. A date-only title can anchor a short note.
   const ownRelation=homeGreetingDayRelation(clause,record,date);
   const relation=ownRelation||(!/今天|今日|今晚|今早|今晨|明天|明日|明早|明晚|后天|昨天|昨日|\d\s*月|\d{1,2}\s*[/.]\s*\d{1,2}|\d{4}\s*[-/.年]|每/.test(clause)?homeGreetingDayRelation(datedText,record,date):null);
   if(!relation)continue;
   const time=homeGreetingEventTime(clause,date);if(!time)continue;
   const minutes=date.getHours()*60+date.getMinutes();
   const rank=time.timing==='now'?0:time.timing==='upcoming'?1:time.timing==='anytime'?2:3;
   const recorded=homeGreetingValidDate(record.createdAt),recordedDateKey=recorded?homeGreetingDateKey(recorded):null;
   candidates.push({id:record.id,title:record.title,text:clause,relation,recordedDateKey,...time,rank,distance:time.timeMinutes===null?0:Math.abs(time.timeMinutes-minutes)});
  }
 }
 candidates.sort((a,b)=>a.rank-b.rank||a.distance-b.distance||a.id.localeCompare(b.id));
 if(!candidates.length)return null;
 const {rank,distance,...event}=candidates[0];return event;
}
function homeGreetingPickPreference(records,date){
 const hour=date.getHours(),weekend=[0,6].includes(date.getDay()),candidates=[];
 const explicit=/偏好|喜欢|不喜欢|不爱|不吃|不喝|忌口|过敏|习惯|通常|一般会|总是|尽量|我更|我只|我不要|我不想|不要放|不要加/;
 const topics=[
  ['meal',/外卖|饮食|吃饭|饭菜|餐食|口味|忌口|过敏|清淡|盐|油|素食|香菜|花生|海鲜|辣|午餐|晚餐|早餐/,(hour>=11&&hour<14)||(hour>=17&&hour<20)],
  ['drink',/咖啡|拿铁|美式|饮品|奶茶|少糖|无糖|半糖|少冰|去冰|燕麦奶|乳糖/,hour>=6&&hour<11],
  ['travel',/旅行|旅游|徒步|博物馆|海边|景点|出行|直飞|红眼航班/,weekend],
  ['routine',/早起|起床|早睡|睡觉|睡前|作息|闹钟|运动|跑步|健身/,(hour>=5&&hour<10)||hour>=19],
 ];
 for(const record of records){
  for(const text of homeGreetingClauses(record.text,100)){
   if(record.kind!=='偏好'&&!explicit.test(text))continue;
   // Dates and unresolved wishes belong in plans, never long-term preferences.
   if(/今天|明天|后天|昨天|\d{4}\s*[-/.年]|\d\s*月|希望|如果|假如|可能|也许|待定|是否|[吗？?]/.test(text))continue;
   let topic='general',score=10;
   for(const [name,pattern,relevant] of topics)if(pattern.test(text)){if(relevant){topic=name;score=50;break}if(topic==='general'){topic=name;score=5}}
   // A topic-specific preference stays out of unrelated moments. A truly
   // general preference remains available as a lower-priority fallback.
   if(score===5)continue;
   candidates.push({id:record.id,title:record.title,text,topic,score});
  }
 }
 candidates.sort((a,b)=>b.score-a.score||a.id.localeCompare(b.id));
 if(!candidates.length)return null;
 const {score,...preference}=candidates[0];return preference;
}
function homeGreetingContext(date=new Date()){
 if(!(date instanceof Date)||!Number.isFinite(date.getTime()))date=new Date();
 const hour=date.getHours(),weekday=date.getDay(),dateKey=homeGreetingDateKey(date);
 const [,period,salutation]=homeGreetingPeriods.find(([end])=>hour<end);
 const memory=homeGreetingUserRecords();
 const event=memory.enabled?homeGreetingPickEvent(memory.records,date):null;
 const preference=memory.enabled&&!event?homeGreetingPickPreference(memory.records,date):null;
 const memoryIds=event?[event.id]:preference?[preference.id]:[];
 const signature=homeGreetingContextHash(JSON.stringify({dateKey,slice:Math.floor((hour*60+date.getMinutes())/5),enabled:memory.enabled,records:memory.records,event,preference}));
 return {signature,dateKey,hour,weekday,period,salutation,memoryEnabled:memory.enabled,event,preference,memoryIds};
}

// Local templates quote enabled, relevant memory as written. They do not call
// an AI service or infer weather, calendar access, task completion or travel.
const homeGreetingState={initialized:false,timer:null};
function homeGreetingFallback(date=new Date()){
 const hour=date.getHours(),day=date.getDay();
 if(!Number.isFinite(hour)||!Number.isFinite(day))return '今天也有我在，慢慢来。';
 const weekend=day===0||day===6;
 if(hour<5)return '夜深了，记得让自己好好休息。';
 if(hour<9)return weekend?'早上好，周末可以慢慢来。':'早上好，一起从容开始今天。';
 if(hour<11)return weekend?'上午好，把时间留给喜欢的事。':'上午好，今天也有我帮你。';
 if(hour<14)return weekend?'中午好，周末好好吃顿饭。':'中午好，忙完也记得好好吃饭。';
 if(hour<18)return weekend?'下午好，留点时间给自己。':'下午好，忙里也记得歇一会儿。';
 if(hour<22)return weekend?'晚上好，今天过得怎么样？':'晚上好，今天辛苦啦。';
 return '夜深了，今晚早点休息吧。';
}
function homeGreetingSourceText(value){return typeof value==='string'?value.replace(/\s+/gu,' ').trim():'';}
function homeGreetingFits(text){return Array.from(text).length<=80;}
function homeGreetingDayNumber(key){
 const match=typeof key==='string'&&key.match(/^(\d{4})-(\d{2})-(\d{2})$/);if(!match)return null;
 const [year,month,day]=match.slice(1).map(Number),date=new Date(Date.UTC(year,month-1,day));
 if(date.getUTCFullYear()!==year||date.getUTCMonth()!==month-1||date.getUTCDate()!==day)return null;
 return date.getTime()/86400000;
}
function homeGreetingEventLead(context,item,text){
 if(!/今天|今日|今晚|今早|今晨|今夜|明天|明日|明早|明晚|后天|昨天|昨日/u.test(text))return '你记下的';
 const recorded=homeGreetingDayNumber(item.recordedDateKey),current=homeGreetingDayNumber(context.dateKey);
 if(recorded===null||current===null||recorded===current)return '你记下的';
 if(current-recorded===1)return '今天的安排里，你昨天记下的';
 const [year,month,day]=item.recordedDateKey.split('-').map(Number);
 return '今天的安排里，你在'+(String(year)!==context.dateKey.slice(0,4)?year+'年':'')+month+'月'+day+'日记下的';
}
function homeGreetingMemoryCopy(context,item,kind){
 const salutation=homeGreetingSourceText(context.salutation)||'你好';
 const text=homeGreetingSourceText(item.text),title=homeGreetingSourceText(item.title);
 let suffix;
 if(kind==='event'){
  // A past time is not proof that an event happened. Negated/cancelled records
  // are quoted as notes, never changed into a positive plan or a reminder.
  const cautious=/(不|别|勿|无需|不用|取消|改期|推迟|暂停|停止|避免|尚未|没有|没)/u.test(text);
  suffix=item.timing==='past'?'，还需要帮忙吗？':cautious?'，要一起看看吗？':item.timing==='upcoming'?'，要一起准备吗？':'，需要我帮忙吗？';
  const quoted=salutation+'，'+homeGreetingEventLead(context,item,text)+'「'+text+'」'+suffix;
  if(text&&homeGreetingFits(quoted))return quoted;
 }else{
  const questions={meal:'，今天想吃什么？',drink:'，想喝点什么？',travel:'，有出行安排可以交给我。',routine:'，今天有什么需要帮忙安排的？',general:'，今天想先做点什么？'};
  suffix=questions[item.topic]||questions.general;
  const quoted=salutation+'，记得你说过「'+text+'」'+suffix;
  if(text&&homeGreetingFits(quoted))return quoted;
 }
 // Do not cut a long sentence: its final clause may qualify or negate its start.
 // A short title is explicitly a saved record's title, not a personal fact.
 const recordCopy=salutation+'，'+(kind==='event'?'今天的安排里，':'')+'你保存的「'+title+'」这条记忆，还需要帮忙吗？';
 if(title&&homeGreetingFits(recordCopy))return recordCopy;
 return salutation+(kind==='event'?'，今天的安排里，你记下的那件事还需要帮忙吗？':'，你保存的偏好，我会记着。今天需要帮忙吗？');
}
function homeGreetingForContext(date=new Date()){
 const fallback={text:homeGreetingFallback(date),kind:'fallback',memoryIds:[],title:''};
 if(!Number.isFinite(date.getTime())||typeof homeGreetingContext!=='function')return fallback;
 const context=homeGreetingContext(date);
 if(!context||!context.memoryEnabled)return fallback;
 const event=context.event,preference=context.preference;
 // The context resolver already decides which preference is timely. Repeating
 // that decision with broader day periods would reject its valid hour windows.
 const kind=event?'event':preference?'preference':null;
 const item=kind==='event'?event:kind==='preference'?preference:null;
 if(!item)return fallback;
 const memoryIds=typeof item.id==='string'?[item.id]:(context.memoryIds||[]).filter(id=>typeof id==='string');
 return {text:homeGreetingMemoryCopy(context,item,kind),kind,memoryIds,title:'依据：本机记忆'+(item.title?'「'+item.title+'」':'')+'\n'+item.text};
}
function homeGreetingForDate(date=new Date()){return homeGreetingForContext(date).text;}
function renderHomeGreeting(date=new Date()){
 const target=$('homeGreeting');if(!target)return;
 const greeting=homeGreetingForContext(date);
 if(target.textContent!==greeting.text)target.textContent=greeting.text;
 target.dataset.memoryIds=JSON.stringify(greeting.memoryIds);target.dataset.contextKind=greeting.kind;
 target.title=greeting.title;
}
function stopHomeGreetingTimer(){
 clearInterval(homeGreetingState.timer);homeGreetingState.timer=null;
}
function refreshHomeGreeting(){
 renderHomeGreeting();stopHomeGreetingTimer();
 if(!document.hidden)homeGreetingState.timer=setInterval(renderHomeGreeting,60000);
}
function syncHomeGreetingStorage(event){
 if(![null,'sela-local-memories','sela-local-use-memories'].includes(event.key))return;
 if(typeof state!=='undefined'&&state.toolDetail){
  try{
   if(event.key===null||event.key==='sela-local-memories'){
    const records=JSON.parse(localStorage.getItem('sela-local-memories')||'[]');
    state.toolDetail.memories=Array.isArray(records)?records.filter(record=>record&&typeof record.title==='string'&&typeof record.text==='string'):[];
   }
   if(event.key===null||event.key==='sela-local-use-memories')state.toolDetail.useMemories=localStorage.getItem('sela-local-use-memories')==='true';
  }catch{}
 }
 renderHomeGreeting();
}
function initializeHomeGreeting(){
 if(homeGreetingState.initialized)return;
 homeGreetingState.initialized=true;
 if(typeof detailPersistMemories==='function'){
  const originalPersistMemories=detailPersistMemories;
  detailPersistMemories=function(...args){const result=originalPersistMemories.apply(this,args);renderHomeGreeting();return result;};
 }
 document.addEventListener('visibilitychange',()=>{
  if(document.hidden)stopHomeGreetingTimer();else refreshHomeGreeting();
 });
 window.addEventListener('pageshow',refreshHomeGreeting);
 window.addEventListener('pagehide',stopHomeGreetingTimer);
 window.addEventListener('storage',syncHomeGreetingStorage);
 refreshHomeGreeting();
}
