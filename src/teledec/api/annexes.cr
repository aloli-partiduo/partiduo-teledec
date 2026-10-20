# SPDX-License-Identifier: AGPL-3.0-or-later

module Teledec
  module Api
    # Cases d'annexes rendues par un fournisseur : formulaire (`2054`) →
    # zone de TELEDEC (`KD`) → montant en devise de tenue (arrondi à l'euro
    # par l'extension TELEDEC).
    alias AnnexBoxes = Teledec::Annexes::Boxes
    alias AnnexProvider = Teledec::Annexes::Provider

    # Formulaires d'annexes qu'une extension peut fournir (`Config::ANNEX_FORMS`).
    ANNEX_FORMS = Config.annex_forms

    # Déclare un fournisseur d'annexes de la liasse (A-AMO-2) : une
    # extension qui tient les données d'un formulaire (2054, 2055) les
    # joint ainsi à la liasse transmise à TELEDEC. Le bloc reçoit l'acteur
    # système et l'exercice du socle ; il rend les cases par formulaire et
    # zone de TELEDEC, ou `nil` s'il n'a rien pour cet exercice. Il n'est
    # appelé que si la pièce `code` est active et que le régime de la liasse
    # a l'un des formulaires déclarés. `ArgumentError` : code invalide ou
    # déjà déclaré, formulaire hors des annexes ou déjà fourni par une autre
    # pièce.
    #
    # ```
    # Teledec::Api.register_annexes("AMORTIS", %w[2054 2055]) do |actor, fiscal_year_id|
    #   Amortis::Api.liasse_annexes(actor, fiscal_year_id)
    # end
    # ```
    def self.register_annexes(code : String, forms : Array(String), &block : Actor, Int64 -> AnnexBoxes?) : AnnexProvider
      Teledec::Annexes.register(code, forms, block)
    end

    # Specs : retire un fournisseur déclaré par un exemple.
    def self.unregister_annexes(code : String) : Nil
      Teledec::Annexes.unregister(code)
    end

    # Fournisseurs déclarés, actifs ou non.
    def self.annex_providers : Array(AnnexProvider)
      Teledec::Annexes.providers
    end
  end
end
