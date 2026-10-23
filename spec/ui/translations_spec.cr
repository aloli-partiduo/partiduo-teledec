# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/TELEDEC/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue dans chaque langue livrée par un administrateur, sur un dossier relié au
# TELEDEC simulé : liasse transmise puis accusée (accusé de réception),
# dépôt au greffe transmis et finalisé (PDF signé), DAS2 préparée. Contrôle
# de l'interface (`PartiduoUi::Translations`) : ni marqueur de traduction
# absente, ni clé brute, ni interpolation non résolue, et toute route
# atteinte par les liens des pages.

private alias S = Teledec::SpecSupport
private alias Api = Teledec::Api
private alias Books = PartiduoUi::Books

describe "Traductions des écrans TELEDEC (langues livrées)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    S.books(greffe: true)
    Books.sale(Books.card("CUSTOMER", "Atelier Morel").code, "1000")
    S.fees(S.supplier("Cabinet Durand"), "1500")
    S.connect
    liasse = Api.transmit(S.admin, S.liasse.id).value!
    S.teledec.acknowledge(S::LIASSE_ID)
    Api.refresh(S.admin, liasse.id).value!
    greffe = Api.transmit(S.admin, S.prepare("greffe", fiscal_year_id: S.fiscal_year_id).id).value!
    S.teledec.finalize_greffe("greffe:732829320:2026-12-31")
    Api.refresh(S.admin, greffe.id).value!
    S.prepare("das2", year: 2026)
    browser = PartiduoUi::Accounts.signed_in

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("teledec:"))
    explorer.crawl(browser, "TELEDEC")
    puts "\nTraductions de TELEDEC : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
