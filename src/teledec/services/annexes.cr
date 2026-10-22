# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Teledec
  # Annexes de la liasse fournies par une extension (A-AMO-2, DECISIONS
  # D-TDC13-001) : une extension qui tient les données d'un formulaire de
  # la liasse (immobilisations et amortissements de `partiduo-amortis` :
  # 2054, 2055) s'enregistre ici avec les formulaires qu'elle remplit ;
  # `Builder` joint ses cases à la liasse (bloc `zones_formulaires` de l'API
  # Balance), comme il joint la 2035 du module `liberal`. TELEDEC ne cite
  # aucune extension : c'est l'extension qui dépend de `partiduo-teledec`
  # (même sens que `Partiduo::Api::Liberal.register_asset_source`).
  #
  # * Seul un fournisseur *actif* (pièce du registre) est consulté, avec
  #   l'acteur système, et seulement pour les formulaires du régime de la
  #   liasse (`Config.annex_forms` : 2054 et 2055 du réel normal, 2033-C
  #   du simplifié) ; un formulaire déclaré d'un autre régime est écarté
  #   sans erreur, le fournisseur ne connaissant pas le régime ;
  # * un formulaire n'a qu'un fournisseur : un second est refusé à
  #   l'enregistrement (`ArgumentError`, erreur de composition de la
  #   distribution, vue au démarrage) ;
  # * un fournisseur qui échoue, rend un formulaire qu'il n'a pas déclaré
  #   ou une zone inconnue du millésime : contrôle bloquant ;
  # * les fournisseurs retenus et l'empreinte des cases jointes sont notés
  #   dans le document (`details["annexes"]`, `details["annexes_fingerprint"]`).
  #
  # Interne : l'enregistrement passe par `Teledec::Api.register_annexes`.
  module Annexes
    alias Boxes = Hash(String, Hash(String, BigDecimal))
    alias Block = Proc(Partiduo::Api::Actor, Int64, Boxes?)

    # Fournisseur : pièce du registre, formulaires déclarés, bloc qui rend
    # les cases d'un exercice du socle (`nil` : rien pour cet exercice).
    record Provider, code : String, forms : Array(String), block : Block

    @@providers = [] of Provider

    def self.register(code : String, forms : Array(String), block : Block) : Provider
      unless code.matches?(/\A[A-Z][A-Z0-9_]*\z/)
        raise ArgumentError.new("code de pièce invalide (majuscules, chiffres, _) : #{code}")
      end
      raise ArgumentError.new("fournisseur d'annexes déjà déclaré : #{code}") if @@providers.any?(&.code.==(code))
      raise ArgumentError.new("aucun formulaire déclaré par #{code}") if forms.empty?
      known = Config.annex_forms
      forms.each do |form|
        raise ArgumentError.new("formulaire #{form} hors des annexes de la liasse (#{known.join(", ")})") unless known.includes?(form)
        if owner = @@providers.find(&.forms.includes?(form))
          raise ArgumentError.new("formulaire #{form} déjà fourni par #{owner.code}")
        end
      end
      provider = Provider.new(code, forms.uniq, block)
      @@providers << provider
      provider
    end

    def self.unregister(code : String) : Nil
      @@providers.reject!(&.code.==(code))
    end

    def self.providers : Array(Provider)
      @@providers.dup
    end

    # Cases des annexes d'une liasse du régime `tax_system`, pour
    # l'exercice `fiscal_year_id`, au millésime visé `target` (rang) ;
    # `nil` si aucun fournisseur actif ne joint rien. Contrôles et détails
    # complétés en place.
    def self.collect(tax_system : String, fiscal_year_id : Int64, target : Int32, controls : Array(Api::ControlView),
                     details : Hash(String, String)) : Hash(String, Hash(String, String))?
      wanted = Config.annex_forms(tax_system)
      return if wanted.empty?
      boxes = {} of String => Hash(String, String)
      sources = [] of String
      @@providers.each do |provider|
        forms = provider.forms & wanted
        next if forms.empty? || !Sources.active?(provider.code)
        joined = call(provider, fiscal_year_id, controls) || next
        part = {} of String => Hash(String, String)
        joined.each do |form, values|
          unless provider.forms.includes?(form)
            controls << Builder.error("teledec.controls.annex_form", {"source" => provider.code, "form" => form})
            next
          end
          # Formulaire déclaré mais d'un autre régime (2054 pour une
          # liasse simplifiée) : le fournisseur ne connaît pas le régime de
          # la liasse, il rend tout ce qu'il sait remplir (D-TDC13-002).
          next unless forms.includes?(form)
          next if values.empty?
          part[form] = values.transform_values { |amount| Money.euros_text(amount) }
        end
        next if part.empty?
        # Zone hors du schéma de TELEDEC au millésime de la liasse : ignorée
        # par TELEDEC sans erreur, donc refusée ici (comme pour la 2035).
        Remote::Formats.unknown_zones(part, target).each do |zone|
          controls << Builder.error("teledec.controls.annex_zone_unknown", {"zone" => zone, "source" => provider.code})
        end
        boxes.merge!(part)
        sources << "#{provider.code}:#{part.keys.sort!.join("+")}"
      end
      return if boxes.empty?
      details["annexes"] = sources.join(",")
      details["annexes_fingerprint"] = fingerprint(boxes)
      boxes
    end

    # Empreinte SHA-256 des cases jointes, formulaires et zones triés.
    def self.fingerprint(boxes : Hash(String, Hash(String, String))) : String
      text = String.build do |io|
        boxes.keys.sort!.each do |form|
          boxes[form].to_a.sort_by!(&.[0]).each { |(zone, amount)| io << form << ' ' << zone << ' ' << amount << '\n' }
        end
      end
      Digest::SHA256.hexdigest(text)
    end

    private def self.call(provider : Provider, fiscal_year_id : Int64, controls : Array(Api::ControlView)) : Boxes?
      provider.block.call(Partiduo::Api::Actor.system, fiscal_year_id)
    rescue ex
      Log.warn(exception: ex) { "TELEDEC : annexes de #{provider.code} indisponibles" }
      controls << Builder.error("teledec.controls.annex_failed", {"source" => provider.code})
      nil
    end
  end
end
