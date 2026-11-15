defmodule Toscanini.PodcastSlugTest do
  use ExUnit.Case, async: true

  alias Toscanini.PodcastSlug

  describe "slug/1" do
    test "nil e vazio" do
      assert PodcastSlug.slug(nil) == nil
      assert PodcastSlug.slug("") == nil
      assert PodcastSlug.slug("   ") == nil
    end

    test "minúsculo, sem acento, espaço → hífen" do
      assert PodcastSlug.slug("Falando de História") == "falando-de-historia"
      assert PodcastSlug.slug("Imposturas Filosóficas") == "imposturas-filosoficas"
      assert PodcastSlug.slug("Slavoj Žižek Collected Recordings") == "slavoj-zizek-collected-recordings"
      assert PodcastSlug.slug("Vanessa Wingårdh") == "vanessa-wingardh"
      assert PodcastSlug.slug("NÃO IMPORTA") == "nao-importa"
    end

    test "ponto final (pasta inválida no Windows) some" do
      assert PodcastSlug.slug("Scott & Mark Learn To...") == "scott-mark-learn-to"
      assert PodcastSlug.slug("Aqui a música toca. | Osesp") == "aqui-a-musica-toca-osesp"
    end

    test "símbolos de URL somem" do
      assert PodcastSlug.slug("#Provocast") == "provocast"
      assert PodcastSlug.slug("@ArquivoOcultoTech") == "arquivoocultotech"
      assert PodcastSlug.slug("Theo - t3․gg") == "theo-t3-gg"
      assert PodcastSlug.slug("80,000 Hours Podcast") == "80-000-hours-podcast"
      assert PodcastSlug.slug("Spring I/O") == "spring-i-o"
    end

    test "apóstrofo não separa palavra; grafias equivalentes coincidem" do
      assert PodcastSlug.slug("Lenny's Podcast: Product | Career | Growth") ==
               "lennys-podcast-product-career-growth"

      assert PodcastSlug.slug("Lenny’s Podcast: Product | Career | Growth") ==
               PodcastSlug.slug("Lenny's Podcast: Product | Career | Growth")
    end

    test "nomes reservados do Windows ganham sufixo" do
      assert PodcastSlug.slug("Nul") == "nul-podcast"
      assert PodcastSlug.slug("CON") == "con-podcast"
      assert PodcastSlug.slug("Aux.") == "aux-podcast"
      assert PodcastSlug.slug("COM1") == "com1-podcast"
      assert PodcastSlug.slug("LPT9") == "lpt9-podcast"
      assert PodcastSlug.slug("Console") == "console"
    end

    test "nome sem letra latina vira podcast-<hash> estável" do
      s = PodcastSlug.slug("梅一生")
      assert s =~ ~r/^podcast-[0-9a-f]{8}$/
      assert PodcastSlug.slug("梅一生") == s
      assert PodcastSlug.slug("Leo Imamura 梅一生 Official Channel") == "leo-imamura-official-channel"
    end

    test "limite de 80 caracteres em fronteira de palavra" do
      s = PodcastSlug.slug(String.duplicate("palavra ", 30))
      assert byte_size(s) <= 80
      refute String.ends_with?(s, "-")
      assert String.ends_with?(s, "palavra")
    end

    test "invariante: sempre [a-z0-9-], sem hífen nas pontas, não reservado" do
      for name <- [
            "Scott & Mark Learn To...",
            "...",
            "---",
            "Nul",
            "#Provocast",
            "Boa Noite Internet",
            "Ilustríssima Conversa",
            "Leo Imamura 梅一生 Official Channel",
            "梅一生",
            "Theo - t3․gg",
            "Gentlemen's Collective",
            "Visual+mente",
            "Maestros.mp4",
            "lore.invest"
          ] do
        s = PodcastSlug.slug(name)
        assert s =~ ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, "#{inspect(name)} → #{inspect(s)}"
        refute s in ~w(con prn aux nul), "#{inspect(name)} → #{inspect(s)}"
      end
    end
  end
end
