export type Device = { id:string; hostname:string; agent_version:string; status:string; last_seen_at:string; inventory_collected_at:string|null; software_count?:number };
export type DeviceEvent = { event_id:string; occurred_at:string; event_type:string; user_name:string|null; payload:Record<string,unknown>; devices?:{hostname:string} };
export type Release = { id:string; version:string; active:boolean; created_at:string };
export type Software = { device_id:string; inventory_key:string; name:string; version:string|null; publisher:string|null; scope:string|null; architecture:string|null; devices?:{hostname:string} };
export type JobTarget = { status:string; leased_at:string|null; completed_at:string|null; result:Record<string,unknown>|null; devices?:{hostname:string}; jobs?:{type:string;created_at:string} };
export type DashboardData = { configured:boolean; devices:Device[]; events:DeviceEvent[]; releases:Release[]; software:Software[]; jobs:JobTarget[]; softwareTotal:number; retentionDays:number };

const demo: DashboardData = {
  configured:false,
  devices:[
    {id:"1",hostname:"LAB01-PC01",agent_version:"2.0.0",status:"online",last_seen_at:new Date().toISOString(),inventory_collected_at:new Date().toISOString(),software_count:47},
    {id:"2",hostname:"LAB01-PC07",agent_version:"2.0.0",status:"online",last_seen_at:new Date(Date.now()-120000).toISOString(),inventory_collected_at:new Date().toISOString(),software_count:44},
    {id:"3",hostname:"LAB02-PC12",agent_version:"1.0.0",status:"offline",last_seen_at:new Date(Date.now()-86400000).toISOString(),inventory_collected_at:null,software_count:39},
  ],
  events:[
    {event_id:"e1",occurred_at:new Date(Date.now()-180000).toISOString(),event_type:"ProhibitedApplicationDetected",user_name:"IFMS\\ana.silva",payload:{displayName:"Roblox"},devices:{hostname:"LAB01-PC07"}},
    {event_id:"e2",occurred_at:new Date(Date.now()-720000).toISOString(),event_type:"SessionLocked",user_name:"IFMS\\aluno.teste",payload:{},devices:{hostname:"LAB01-PC01"}},
  ],
  releases:[{id:"r1",version:"2.0.0",active:true,created_at:new Date().toISOString()}], softwareTotal:130,
  software:[
    {device_id:"1",inventory_key:"s1",name:"LibreOffice",version:"25.2",publisher:"The Document Foundation",scope:"machine",architecture:"x64",devices:{hostname:"LAB01-PC01"}},
    {device_id:"2",inventory_key:"s2",name:"Google Chrome",version:"140",publisher:"Google LLC",scope:"machine",architecture:"x64",devices:{hostname:"LAB01-PC07"}},
  ],
  jobs:[],
  retentionDays:90,
};

async function rest(path:string){
  const url=process.env.SUPABASE_URL; const key=process.env.SUPABASE_SECRET_KEY;
  if(!url||!key) throw new Error("Supabase não configurado");
  const response=await fetch(`${url}/rest/v1/${path}`,{headers:{apikey:key,Authorization:`Bearer ${key}`},cache:"no-store"});
  if(!response.ok) throw new Error(`Supabase ${response.status}`); return response.json();
}

export async function getDashboardData():Promise<DashboardData>{
  try{
    const [devices,events,releases,inventory,jobs,settings]=await Promise.all([
      rest("devices?select=id,hostname,agent_version,status,last_seen_at,inventory_collected_at&order=hostname"),
      rest("device_events?select=event_id,occurred_at,event_type,user_name,payload,devices(hostname)&order=occurred_at.desc&limit=20"),
      rest("agent_releases?select=id,version,active,created_at&order=created_at.desc"),
      rest("software_inventory?select=device_id,inventory_key,name,version,publisher,scope,architecture,devices(hostname)&order=name&limit=5000"),
      rest("device_jobs?select=status,leased_at,completed_at,result,devices(hostname),jobs(type,created_at)&order=leased_at.desc.nullslast&limit=30"),
      rest("system_settings?select=event_retention_days&id=eq.true&limit=1"),
    ]);
    const counts=new Map<string,number>(); for(const row of inventory) counts.set(row.device_id,(counts.get(row.device_id)??0)+1);
    return {configured:true,devices:devices.map((d:Device)=>({...d,software_count:counts.get(d.id)??0})),events,releases,software:inventory,jobs,softwareTotal:inventory.length,retentionDays:settings[0]?.event_retention_days??90};
  }catch{return demo;}
}
