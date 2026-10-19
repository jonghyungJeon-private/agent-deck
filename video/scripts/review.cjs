const path=require('path');const fs=require('fs');
const {bundle}=require('@remotion/bundler');
const {openBrowser,selectComposition,renderStill}=require('@remotion/renderer');
const V=path.resolve(__dirname,'..');process.chdir(V);
(async()=>{
 fs.mkdirSync(path.join(V,'.work/review'),{recursive:true});
 fs.appendFileSync(path.join(V,'.work/pids.log'),`${process.pid} review-renderer\n`);
 const serveUrl=await bundle({entryPoint:path.join(V,'src/index.ts'),outDir:path.join(V,'.work/review-bundle')});
 const browser=await openBrowser('chrome');
 try{
  const composition=await selectComposition({serveUrl,id:'AgentDeckIntro',browserInstance:browser});
  for(const frame of [90,300,600,840,1170,1545,1740,1920,2040,2190,2340,2410,2610]){
   await renderStill({serveUrl,composition,browserInstance:browser,frame,output:path.join(V,`.work/review/frame-${String(frame).padStart(4,'0')}.png`),imageFormat:'png'});
   process.stdout.write(`Reviewed still ${frame}\n`);
  }
 }finally{await browser.close({silent:true});}
})().catch(e=>{process.stderr.write(e.stack+'\n');process.exit(1);});
