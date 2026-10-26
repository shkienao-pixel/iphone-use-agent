(function () {
  const C = {fg:'var(--foreground)',bg:'var(--background)',node:'var(--muted)',line:'var(--muted-foreground)',border:'var(--border)',blue:'var(--viz-series-1)'};
  const esc = v => String(v).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
  function wrap(value,width,size=12) {
    const result=[]; let line='',used=0;
    for(const char of String(value)){
      const unit=/[\u0000-\u007f]/.test(char)?size*.56:size;
      if(used+unit>width && line){result.push(line);line='';used=0;}
      line+=char;used+=unit;
    }
    if(line)result.push(line);return result;
  }
  function drawing(id,w){
    let out='';
    const rect=(x,y,width,height,kind='node')=>{
      out+=`<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${kind==='boundary'?10:6}" fill="${kind==='boundary'?'none':C.node}" stroke="${kind==='boundary'?C.line:C.border}" stroke-width="1.2" ${kind==='boundary'?'stroke-dasharray="6 5"':''}/>`;
    };
    const text=(x,y,value,size=12,anchor='middle',strong=false,color=C.fg)=>{out+=`<text x="${x}" y="${y}" text-anchor="${anchor}" font-size="${size}" font-weight="${strong?500:400}" fill="${color}">${esc(value)}</text>`;};
    const label=(x,y,value,width=100)=>{
      const lines=wrap(value,width,12); const h=lines.length*17+6;
      out+=`<rect x="${x-width/2}" y="${y-14}" width="${width}" height="${h}" fill="${C.bg}"/>`;
      lines.forEach((line,i)=>text(x,y+i*17,line,12,'middle',false,C.line));
    };
    const note=(x,y,value,width)=>{const lines=wrap(value,width,12);lines.forEach((line,i)=>text(x,y+i*18,line,12,'start',false,C.line));return lines.length*18;};
    const arrow=(points,caption='',options={})=>{
      const pts=points.map(p=>p.join(',')).join(' ');
      out+=`<polyline points="${pts}" fill="none" stroke="${options.data?C.blue:C.line}" stroke-width="1.4" marker-end="url(#${id}-${options.data?'blue':'gray'})" ${options.both?`marker-start="url(#${id}-${options.data?'blue':'gray'}-start)"`:''} ${options.data?'stroke-dasharray="5 4"':''}/>`;
      if(caption){const p=options.at || [(points[0][0]+points.at(-1)[0])/2,(points[0][1]+points.at(-1)[1])/2-6];label(p[0],p[1],caption,options.labelWidth||92);}
    };
    const box=(x,y,width,height,title,sub=[],options={})=>{
      rect(x,y,width,height);
      const titleLines=wrap(title,width-24,14);
      const subLines=sub.flatMap(line=>wrap(line,width-28,12));
      const total=titleLines.length*20+(subLines.length?9:0)+subLines.length*18;
      let ty=y+(height-total)/2+15;
      titleLines.forEach(line=>{text(x+width/2,ty,line,14,'middle',true);ty+=20;});
      if(subLines.length)ty+=7;
      subLines.forEach(line=>{text(x+width/2,ty,line,12,'middle',false,C.line);ty+=18;});
      return {x,y,w:width,h:height,cx:x+width/2,cy:y+height/2};
    };
    const frame=(x,y,width,height,title)=>{rect(x,y,width,height,'boundary');text(x+14,y+24,title,12,'start',true);};
    const finish=(h,title)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img" aria-label="${esc(title)}" font-family="inherit"><title>${esc(title)}</title><defs>${['gray','blue'].map(k=>`<marker id="${id}-${k}" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M1 1 L7 4 L1 7Z" fill="${k==='blue'?C.blue:C.line}"/></marker><marker id="${id}-${k}-start" viewBox="0 0 8 8" refX="1" refY="4" markerWidth="6" markerHeight="6" orient="auto"><path d="M7 1 L1 4 L7 7Z" fill="${k==='blue'?C.blue:C.line}"/></marker>`).join('')}</defs>${out}</svg>`;
    return {rect,text,label,note,arrow,box,frame,finish};
  }
  function system(w){
    const d=drawing('system',w), {box,arrow,frame,text}=d;
    if(w>=640){
      const pw=Math.round((w-128)*.64), extX=pw+112, ew=w-extX-16;
      const app={x:32,y:170,w:pw-32,h:220};
      box(32,14,pw-32,64,'用户',['文字 · 语音 · Siri · 附件']);
      frame(16,116,pw,514,'iPhone · 本机运行边界');
      box(app.x,app.y,app.w,app.h,'Sela App',['统一交互入口','对话理解与任务协调','屏幕任务 / 原生任务 / 专属服务','状态、回执与本机数据']);
      arrow([[pw/2+16,78],[pw/2+16,170]],'用户请求',{at:[pw/2+16,109]});
      const cw=(pw-48)/2;
      const os=box(32,500,cw,90,'iOS 原生能力',['日历 · 提醒 · 健康','音乐 · 位置 · 内容']);
      const target=box(48+cw,500,cw,90,'前台目标 App',['iOS HID','AssistiveTouch']);
      arrow([[os.cx,390],[os.cx,500]],'原生 API');
      arrow([[target.cx,500],[target.cx,390]],'共享画面',{data:true,at:[target.cx,448]});
      box(extX,174,ew,82,'配置的模型服务',['文字 / 图像请求','结构化决策 / 回答']);
      arrow([[pw,215],[extX,215]],'HTTPS',{both:true,labelWidth:76});
      box(extX,304,ew,82,'业务服务平台',['携程 · 美团等','查询、报价与受控提交']);
      arrow([[pw,345],[extX,345]],'服务调用',{both:true,labelWidth:76});
      box(extX,500,ew,90,'ESP32-S3 配件',['命令执行 · 键鼠 HID','状态反馈 · 输入看门狗']);
      arrow([[pw,376],[pw+48,376],[pw+48,458],[extX+ew/2,458],[extX+ew/2,500]],'BLE 命令 / 状态',{both:true,at:[extX+ew/2,453],labelWidth:118});
      arrow([[extX,545],[target.x+target.w,545]],'系统 HID',{labelWidth:78});
      text(16,660,'实线：调用或系统输入　　蓝色虚线：用户授权的观察数据',12,'start',false,C.line);
      return d.finish(682,'系统边界：iPhone 内的 Sela 与系统能力，手机外的模型、业务服务与 ESP32 配件');
    }
    const x=22,bw=w-44;
    box(x,10,bw,64,'用户',['文字 · 语音 · Siri · 附件']);
    arrow([[w/2,74],[w/2,142]],'用户请求');
    frame(10,108,w-20,422,'iPhone · 本机运行边界');
    box(x,142,bw,130,'Sela App',['统一交互与对话理解','任务协调与三条执行通道','状态、回执与本机数据']);
    arrow([[w/2,272],[w/2,338]],'原生 API',{labelWidth:100});
    box(x,338,bw,72,'iOS 原生能力',['日历 · 提醒 · 健康 · 音乐等']);
    box(x,434,bw,72,'前台目标 App',['接收 HID 输入 · 向 Sela 共享画面']);
    text(22,568,'手机外的协作边界',12,'start',true);
    box(x,590,bw,92,'配置的模型服务',['Sela ↔ HTTPS','任务、图像 ↔ 决策、回答']);
    box(x,706,bw,92,'业务服务平台',['Sela ↔ 官方服务','查询、报价与受控提交']);
    box(x,822,bw,112,'ESP32-S3 配件',['Sela ↔ BLE 命令与状态','配件 → 系统 HID → 前台 App']);
    return d.finish(950,'系统边界：iPhone 本机及手机外的三类协作方');
  }
  function layers(w){
    const d=drawing('layers',w),{box,arrow,text}=d;const wide=w>=640;
    const left=wide?100:16,bw=w-left-16;let y=20;
    const rows=[['交互层','统一会话与结果展示',['文字 · 语音 · Siri · 附件']],['理解层','对话上下文与意图路由',['当前人类请求 + 有来源的参考资料']],['协调层','应用协调与任务归属',['任务 ID · 会话 token · 队列 · 授权状态']]];
    rows.forEach((row,i)=>{if(wide)text(16,y+38,row[0],12,'start',true);else text(16,y+12,row[0],12,'start',true);const yy=y+(wide?0:27);box(left,yy,bw,80,row[1],row[2]);if(i<2)arrow([[left+bw/2,yy+80],[left+bw/2,yy+124]],i===0?'本轮请求':'结构化意图',{at:[left+bw/2,yy+108]});y=yy+124;});
    const entries=[['屏幕任务',['单一 GUI 所有者','AgentEngine / Harness']],['原生任务',['最多 3 项并发','tools-only AgentEngine']],['专属会话',['航班 / 跑腿','领域对话与卡片']]];
    const adapters=[['屏幕与输入适配',['Capture / OCR / BLE']],['系统能力适配',['SystemTools / iOS SDK']],['领域服务适配',['Ctrip / Paotui Client']]];
    if(wide){
      text(16,y+45,'执行层',12,'start',true);const gap=16,cw=(bw-2*gap)/3;
      arrow([[left+bw/2,y-44],[left+bw/2,y-18],[left+cw/2,y-18],[left+cw/2,y]],'');
      arrow([[left+bw/2,y-18],[left+2*(cw+gap)+cw/2,y-18],[left+2*(cw+gap)+cw/2,y]],'');
      arrow([[left+bw/2,y-18],[left+bw/2,y]],'');
      entries.forEach((a,i)=>box(left+i*(cw+gap),y,cw,112,a[0],a[1]));
      text(16,y+203,'适配层',12,'start',true);
      adapters.forEach((a,i)=>{const cx=left+i*(cw+gap)+cw/2;arrow([[cx,y+112],[cx,y+174]],'受控调用',{labelWidth:76});box(left+i*(cw+gap),y+174,cw,88,a[0],a[1]);});y+=300;
    } else {
      text(16,y+4,'执行通道与对应适配器',12,'start',true);y+=24;
      entries.forEach((a,i)=>{box(left,y,bw,92,a[0],a[1]);arrow([[left+bw/2,y+92],[left+bw/2,y+132]],'');box(left,y+132,bw,76,adapters[i][0],adapters[i][1]);y+=242;});
    }
    box(16,y,w-32,106,'横向支撑底座',['记忆与上下文 · 历史与检查点 · 权限与回执','通知 / 灵动岛 / PiP · 诊断与阶段计时']);
    return d.finish(y+124,'App 分层：交互、理解、协调、三条执行通道、能力适配和共享支撑');
  }
  function loop(w){
    const d=drawing('loop',w),{box,arrow,text,note}=d;const x=w>=640?100:60,bw=w-x-18;let y=20;
    const rows=[['获取当前画面',['CaptureService / FrameReadiness','系统确认时间与输入边界']],['本地解释与上下文',['OCR / 页面适配 / Harness','任务、记忆、附件与实际回执']],['模型提出动作',['VisionClient → AgentAction','动作是提议，由宿主决定是否派发']],['宿主执行前复核',['流 / 尺寸 / 变化 / 取消 / 授权','画面失效则丢弃动作、重新观察']],['受控执行',['MouseExecutor / phone_tool / system_tool','单一输入所有者与稳定操作身份']],['结果取证与持久化',['新画面 + 工具回执 + 完成策略','先保存记录，再发布终态']]];
    const h=w>=640?96:116,gap=50,centers=[];
    rows.forEach((r,i)=>{text(x-30,y+h/2+5,String(i+1).padStart(2,'0'),14,'middle',true);box(x,y,bw,h,r[0],r[1]);centers.push(y);if(i<rows.length-1)arrow([[x+bw/2,y+h],[x+bw/2,y+h+gap]],i===2?'结构化动作':i===3?'校验通过':'',{labelWidth:96});y+=h+gap;});
    const rail=16;
    arrow([[x+bw/2,y-gap],[x+bw/2,y-gap+22],[rail,y-gap+22],[rail,8],[x+bw/2,8],[x+bw/2,20]],'',{data:true});
    if(w>=640){text(36,(y-gap)/2,'未完成',12,'start',false,C.blue);text(36,(y-gap)/2+20,'再观察',12,'start',false,C.blue);}
    const nh=note(x,y-8,'完成 / 需要人工处理 / 失败 / 停止 → 退出本轮',bw);
    return d.finish(y+nh+12,'GUI 单轮闭环：取屏、解释、决策、复核、执行与结果取证；未完成才进入下一轮');
  }
  function lanes(w){
    const d=drawing('lanes',w),{box,arrow,text,frame}=d;const wide=w>=680;const gap=24,cw=wide?(w-32-2*gap)/3:w-48;
    const cols=[{title:'屏幕操控通道',limit:'单一 GUI 所有者',steps:[['屏幕任务队列',['顺序 / 暂停 / 显式恢复']],['视觉执行器',['AgentEngine + Harness']],['画面与输入适配',['Capture / OCR','MouseExecutor']],['配件与系统输入',['BLE → ESP32 → iOS HID']]]},{title:'原生任务通道',limit:'最多 3 项；同资源互斥',steps:[['原生任务池',['BackgroundTaskCoordinator']],['独立原生执行器',['每项 tools-only AgentEngine']],['资源锁与工具门禁',['TaskResourceGate','SystemTools']],['原生能力与服务',['iOS SDK / 受支持客户端']]]},{title:'专属对话通道',limit:'领域会话独立推进',steps:[['航班 / 跑腿对话',['原文、条件与卡片上下文']],['领域状态与策略',['Ctrip / Paotui Conversation']],['专属客户端与存储',['独立凭据 / 报价 / 回执']],['领域服务交互',['HTTPS 查询 / 确认 / 交接']]]}];
    let maxY=0;
    cols.forEach((col,index)=>{const x=wide?16+index*(cw+gap):24,base=wide?20:20+index*660;frame(x-8,base,cw+16,610,col.title);text(x+cw/2,base+52,col.limit,12,'middle',false,C.line);let y=base+78;col.steps.forEach((s,i)=>{box(x,y,cw,88,s[0],s[1]);if(i<3)arrow([[x+cw/2,y+88],[x+cw/2,y+136]],'');y+=136;});maxY=Math.max(maxY,base+610);});
    const foot=maxY+30;box(16,foot,w-32,104,'统一回执与会话结果投影',['taskID / conversationID 绑定；执行状态与外部业务结果分开','首次系统授权与前台专用能力仍受系统门禁约束']);
    return d.finish(foot+126,'三条任务通道：屏幕任务串行、原生任务有限并发、专属会话直接调用领域服务');
  }
  function hardware(w){
    const d=drawing('hardware',w),{box,arrow,frame,text,note}=d;const x=30,bw=w-60;const hh=w>=640?94:116;
    frame(14,16,w-28,hh+64,'iPhone · Sela App');box(x,60,bw,hh,'BLETransport',['CoreBluetooth 控制通道','版本化命令 / 状态 / 连接代次']);
    arrow([[w/2,hh+80],[w/2,hh+186]],'加密控制连接 · 命令 / 状态',{both:true,labelWidth:210});
    const mid=hh+170;frame(14,mid,w-28,292,'ESP32-S3 · ESP-IDF / NimBLE');box(x,mid+48,bw,86,'自定义 GATT 与命令执行',['Command / Status / Task','协议校验 → 板端定时执行']);
    const cw=(bw-24)/3;
    if(w>=640){['相对移动与点击','键盘与组合键','释放与看门狗'].forEach((v,i)=>box(x+i*(cw+12),mid+166,cw,66,v));text(w/2,mid+266,'独立 RGB 状态任务 · 配对资料 NVS',12,'middle',false,C.line);}
    else{box(x,mid+156,bw,106,'固件职责',['移动 / 点击 / 键盘 / 释放','看门狗 / RGB / NVS']);}
    arrow([[w/2,mid+292],[w/2,mid+396]],'系统 HID 连接 · 鼠标 / 键盘报告',{labelWidth:224});
    const bottom=mid+380;frame(14,bottom,w-28,194,'同一台 iPhone · 系统输入侧');
    if(w>=640){const cw=(bw-64)/2;box(x,bottom+64,cw,86,'iOS HID / AssistiveTouch');box(x+cw+64,bottom+64,cw,86,'前台目标 App');arrow([[x+cw,bottom+107],[x+cw+64,bottom+107]],'输入',{labelWidth:44});}
    else box(x,bottom+62,bw,106,'iOS 系统输入',['HID / AssistiveTouch','→ 前台目标 App']);
    const nh=note(20,bottom+228,'传输或释放确认，只证明输入协议状态；业务结果由新画面与回执核验。',w-40);
    return d.finish(bottom+240+nh,'配件协议：App 的 BLE 控制连接和系统 HID 输入连接分别管理，ESP32 执行键鼠输入');
  }
  function data(w){
    const d=drawing('data',w),{box,arrow,text}=d;const wide=w>=640,gap=22,cw=wide?(w-32-gap)/2:w-32;let end=0;
    const domains=[['会话与任务',['对话消息 · 任务历史 · 屏幕队列','任务 ID · 补充要求 · 检查点']],['长期记忆',['手动索引 · 五个基础文档','事实来源 · 自动学习 · 接收方边界']],['证据与产物',['聊天 / 笔记可见证据 · 文件原件','工具回执 · 工作流日志 · 导出产物']],['配置与凭据',['UserDefaults：配置和偏好','Keychain：模型及业务连接凭据']]];
    domains.forEach((a,i)=>{const x=wide?16+(i%2)*(cw+gap):16,y=20+(wide?Math.floor(i/2)*166:i*166);box(x,y,cw,140,a[0],a[1]);end=y+140;});
    let y=end+62;text(16,y,'恢复与未知提交结果',14,'start',true);y+=28;
    const x=wide?100:32,bw=w-x-(wide?100:32),h=78;
    box(x,y,bw,h,'保存原任务与提交意图',['稳定 taskID / operation_id；提交前先落盘']);
    arrow([[w/2,y+h],[w/2,y+h+54]],'');y+=h+54;
    box(x,y,bw,h,'执行并核对实际结果',['新观察 / 真实回执；模型声明不是完成证据']);y+=h;
    if(wide){const branchY=y+64,cw=(bw-24)/2;arrow([[w/2,y],[w/2,y+30],[x+cw/2,y+30],[x+cw/2,branchY]],'');arrow([[w/2,y+30],[x+cw+24+cw/2,y+30],[x+cw+24+cw/2,branchY]],'');box(x,branchY,cw,82,'结果已确认',['保存回执并发布终态']);box(x+cw+24,branchY,cw,82,'结果未知',['保留原操作，进入人工核验']);arrow([[x+cw+24+cw/2,branchY+82],[x+cw+24+cw/2,branchY+130]],'');box(x+cw+24,branchY+130,cw,82,'明确恢复或结束',['核验后决定；不自动重发']);y=branchY+212;}
    else{arrow([[w/2,y],[w/2,y+48]],'');y+=48;box(x,y,bw,100,'结果分类',['已确认 → 保存回执与终态','未知 → 保留原操作，人工核验']);arrow([[w/2,y+100],[w/2,y+148]],'');y+=148;box(x,y,bw,90,'核验后明确恢复或结束',['不重建身份，不自动重放未知提交']);y+=90;}
    return d.finish(y+24,'数据与恢复：四类本机数据域，以及未知提交结果的保守核验路径');
  }
  globalThis.SelaArchitecture={draw:(id,width)=>({system,layers,loop,lanes,hardware,data}[id])(Math.round(width))};
})();
