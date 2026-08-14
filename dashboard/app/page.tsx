import { Dashboard } from "./Dashboard";
import { getDashboardData } from "./lib/supabase";
import { getChatGPTUser } from "./chatgpt-auth";

export const dynamic = "force-dynamic";

export default async function Home() {
  const [data, user] = await Promise.all([getDashboardData(), getChatGPTUser()]);
  return <Dashboard initialData={data} operatorName={user?.displayName ?? "Administrador IFMS"} />;
}

