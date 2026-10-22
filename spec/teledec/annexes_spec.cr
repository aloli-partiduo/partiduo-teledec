# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Formats = Teledec::Remote::Formats
private alias Payload = Teledec::Payload
private alias Books = PartiduoUi::Books

# Pièce du registre propre à ces exemples : un fournisseur d'annexes n'est
# consulté que si sa pièce est active.
Partiduo::Modules.register do
  code "TDCANNEX"
  name "teledec.module.name"
  version "0.0.1"
  requires_core "~> 0.1"
end

private CODE = "TDCANNEX"

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

# Fournisseur des exemples : 2054 et 2055, cases fixes, exercice noté.
private def provide(&block : Partiduo::Api::Actor, Int64 -> Api::AnnexBoxes?) : Nil
  Api.unregister_annexes(CODE)
  Api.register_annexes(CODE, %w[2054 2055], &block)
  nil
end

private def provide_fixed(boxes : Api::AnnexBoxes) : Nil
  provide { |_, _| boxes }
end

private def sale(amount : String = "1000") : Nil
  Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, amount)
  nil
end

private def identity : Payload::Identity
  Payload::Identity.new("Atelier Brunet SARL", "SARL", "732829320", "", "", "", "12 rue des Arts", "69002", "Lyon", "FR",
    "contact@atelier-brunet.test")
end

private def boxes_of(filing : Api::FilingView) : Hash(String, Hash(String, BigDecimal))
  result = {} of String => Hash(String, BigDecimal)
  filing.boxes.each { |box| (result[box.form] ||= {} of String => BigDecimal)[box.box] = box.amount }
  result
end

private SAMPLE = {
  "2054" => {"LB" => d("1200.40"), "LD" => d("3000"), "MT" => d("4200.40")},
  "2055" => {"QL" => d("240"), "QM" => d("600.50"), "QO" => d("840.50")},
}

describe "Annexes de la liasse fournies par une extension (A-AMO-2, D-TDC13-001)" do
  Spec.after_each { Api.unregister_annexes(CODE) }

  it "relève les zones des annexes 2054 et 2055 au millésime 2023, valables ensuite" do
    Formats.zone_codes("2054", 202301).should eq(Formats::ZONE_2054)
    Formats.zone_codes("2054", 202601).should eq(Formats::ZONE_2054)
    Formats.zone_codes("2055", 202701).should eq(Formats::ZONE_2055)
    Formats::ZONE_2054.size.should eq(144)
    Formats::ZONE_2055.size.should eq(179)
    # Cases booléennes « Déposé néant » : jamais jointes.
    Formats::ZONE_2054.should_not contain("RN")
    Formats::ZONE_2055.should_not contain("UL")
    Formats.unknown_zones({"2054" => {"LB" => "1", "ZZ" => "2"}, "2055" => {"UL" => "1"}}, 202601)
      .should eq(["2054 ZZ", "2055 UL"])
  end

  it "nomme les zones des annexes par le code seul dans le bloc zones_formulaires" do
    boxes = {"2054" => {"LB" => "1200.40"}, "2055" => {"QM" => "600.50"}}
    payload = Payload.new("liasse", %w[2065 2050], identity, "2026-01-01", "2026-12-31", boxes: boxes)
    zones = Formats.liasse_zones(payload) || raise "zones absentes"
    zones.should eq({"2054" => {"LB" => 1200_i64}, "2055" => {"QM" => 601_i64}})
  end

  it "refuse à l'enregistrement un code invalide, un formulaire hors des annexes ou déjà fourni" do
    provide_fixed(SAMPLE)
    expect_raises(ArgumentError, /déjà déclaré/) { Api.register_annexes(CODE, %w[2054]) { |_, _| nil } }
    expect_raises(ArgumentError, /déjà fourni par TDCANNEX/) { Api.register_annexes("AUTRE", %w[2055]) { |_, _| nil } }
    expect_raises(ArgumentError, /hors des annexes/) { Api.register_annexes("AUTRE", %w[2050]) { |_, _| nil } }
    expect_raises(ArgumentError, /code de pièce invalide/) { Api.register_annexes("autre", %w[2054]) { |_, _| nil } }
    Api.annex_providers.map(&.code).should eq([CODE])
  end

  it "joint les cases d'un fournisseur actif à la liasse du réel normal, avec l'empreinte" do
    S.books("is_rn")
    sale
    Partiduo::Api::Modules.activate(S::SYSTEM, CODE).value!
    seen = [] of {Bool, Int64}
    provide do |actor, fiscal_year_id|
      seen << {actor.system, fiscal_year_id}
      SAMPLE
    end
    filing = S.liasse
    seen.should eq([{true, S.fiscal_year_id}])
    filing.ready?.should be_true
    boxes_of(filing).should eq({
      "2054" => {"LB" => d("1200"), "LD" => d("3000"), "MT" => d("4200")},
      "2055" => {"QL" => d("240"), "QM" => d("601"), "QO" => d("841")},
    })
    filing.details["annexes"].should eq("TDCANNEX:2054+2055")
    filing.details["annexes_fingerprint"].should match(/\A[0-9a-f]{64}\z/)
    # Les annexes changent : le dépôt préparé le signale.
    provide_fixed({"2054" => {"LB" => d("1300")}})
    Api.check(S.admin, filing.id).value!.controls.map(&.key).should contain("teledec.controls.changed")
  end

  it "transmet les annexes dans le bloc zones_formulaires, après la balance" do
    S.books("is_rn")
    sale
    S.connect
    Partiduo::Api::Modules.activate(S::SYSTEM, CODE).value!
    provide_fixed(SAMPLE)
    filing = S.liasse
    Api.transmit(S.admin, filing.id).value!
    body = S.teledec.requests.find! { |request| request.path == "/service/liasse" }.body
    sections = S::LiasseBody.parse(body)
    sections.header.should contain("#REEL-NORMAL-OU-SIMPLIFIE NORMAL")
    sections.balance.any?(&.starts_with?("706;")).should be_true
    zones = sections.zones.as_h
    zones.keys.sort!.should eq(%w[2054 2055])
    zones["2054"]["MT"].as_i64.should eq(4200)
    zones["2055"]["QO"].as_i64.should eq(841)
    sections.document["informations_supplementaires"].as_h.should be_empty
  end

  it "ignore un fournisseur inactif, et un fournisseur sans formulaire du régime de la liasse" do
    S.books("is_rn")
    sale
    called = 0
    provide do |_, _|
      called += 1
      SAMPLE
    end
    filing = S.liasse
    called.should eq(0)
    filing.boxes.should be_empty
    filing.details.has_key?("annexes").should be_false

    Partiduo::Api::Modules.activate(S::SYSTEM, CODE).value!
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", false)).value!
    simplified = S.liasse
    called.should eq(0)
    simplified.forms.should eq(%w[2065 2033])
    simplified.boxes.should be_empty
  end

  it "relève les zones de la 2033-C et la nomme 2033C jusqu'en 2024, 2033C2 depuis 2025 (D-TDC13-002)" do
    Formats.zone_codes("2033-C", 202301).should eq(Formats::ZONE_2033C)
    Formats.zone_codes("2033-C", 202701).should eq(Formats::ZONE_2033C)
    Formats::ZONE_2033C.size.should eq(103)
    Formats::ZONE_2033C.should_not contain("RQ")
    Formats::ZONE_2033C.should_not contain("KA")
    Formats.form_name("2033-C", 202401).should eq("2033C")
    Formats.form_name("2033-C", 202501).should eq("2033C2")
    Formats.form_name("2033-C", 202701).should eq("2033C2")
    Formats.form_name("2035-A", 202601).should eq("2035A")
    Teledec::Config.annex_forms("is_rsi").should eq(%w[2033-C])
    Teledec::Config.annex_forms("bic_rsi").should eq(%w[2033-C])
    Teledec::Config.annex_forms("bnc").should be_empty
  end

  it "joint la 2033-C à la liasse simplifiée et écarte sans erreur les annexes du réel normal (D-TDC13-002)" do
    S.books("is_rsi")
    sale
    S.connect
    Partiduo::Api::Modules.activate(S::SYSTEM, CODE).value!
    Api.unregister_annexes(CODE)
    Api.register_annexes(CODE, %w[2054 2055 2033-C]) do |_, _|
      SAMPLE.merge({"2033-C" => {"DE" => d("12000.40"), "GD" => d("2400"), "JD" => d("4800"), "DK" => d("12000.40")}})
    end
    # Le même fournisseur au réel normal : 2054 et 2055 seules.
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rn", "ca3_monthly", false)).value!
    boxes_of(S.liasse).keys.sort!.should eq(%w[2054 2055])
    Api.update_settings(S::SYSTEM, Api::SettingsInput.new("is_rsi", "ca3_monthly", false)).value!

    filing = S.liasse
    filing.forms.should eq(%w[2065 2033])
    filing.ready?.should be_true
    boxes_of(filing).should eq({"2033-C" => {"DE" => d("12000"), "GD" => d("2400"), "JD" => d("4800"), "DK" => d("12000")}})
    filing.details["annexes"].should eq("TDCANNEX:2033-C")

    Api.transmit(S.admin, filing.id).value!
    body = S.teledec.requests.find! { |request| request.path == "/service/liasse" }.body
    zones = S::LiasseBody.parse(body).zones.as_h
    zones.keys.should eq(%w[2033C2])
    zones["2033C2"]["DE"].as_i64.should eq(12000)
  end

  it "bloque la liasse sur une zone inconnue, un formulaire non déclaré ou un fournisseur en échec" do
    S.books("is_rn")
    sale
    Partiduo::Api::Modules.activate(S::SYSTEM, CODE).value!
    provide_fixed({"2054" => {"LB" => d("10"), "ZZ" => d("5")}, "2050" => {"AA" => d("1")}})
    filing = S.liasse
    filing.ready?.should be_false
    filing.errors.map { |control| {control.key, control.params} }.should eq([
      {"teledec.controls.annex_form", {"source" => CODE, "form" => "2050"}},
      {"teledec.controls.annex_zone_unknown", {"zone" => "2054 ZZ", "source" => CODE}},
    ])

    provide { |_, _| raise "panne de l'extension" }
    failed = S.liasse
    failed.errors.map(&.key).should eq(["teledec.controls.annex_failed"])
    failed.boxes.should be_empty

    # Rien pour l'exercice : aucune case, aucun contrôle.
    provide { |_, _| nil }
    S.liasse.ready?.should be_true
  end
end
