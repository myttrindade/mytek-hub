import { createClient } from "@/lib/supabase/server";
import CatalogList from "@/components/CatalogList";

export default async function CatalogoSistemasPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // RLS já filtra sozinho: categoria "pessoal" só volta se created_by for
  // o usuário logado — as outras três categorias voltam pra qualquer um.
  const { data: systems } = await supabase
    .from("catalog_systems")
    .select("*")
    .order("name", { ascending: true });

  return (
    <main className="mx-auto max-w-[1400px] px-6 py-8">
      <CatalogList
        initialSystems={systems ?? []}
        currentUserId={user?.id ?? null}
      />
    </main>
  );
}
