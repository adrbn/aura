<div align="center">

<picture>
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/aura-hero-light.svg">
  <img src="docs/assets/aura-hero.svg" alt="Aura sur deux iPhone et une Apple Watch, en captures de l'app : En cours de lecture et paroles synchronisées, Accueil, une radio et un album" width="860">
</picture>

<img src="docs/assets/icon.png" width="72" height="72" alt="Icône de l'app Aura">

# Aura

**Votre serveur de musique, sur votre iPhone.** Un lecteur natif pour iPhone et Apple Watch, pour Navidrome et Subsonic :
streaming sans perte, paroles qui s'allument mot à mot, mix tirés de ce que vous écoutez vraiment, et toute votre bibliothèque hors ligne.

<a href="https://github.com/adrbn/aura/releases/latest"><img src="docs/assets/btn-download-fr.svg" alt="Télécharger l'IPA" height="40"></a>&nbsp;
<a href="#ce-que-fait-aura"><img src="docs/assets/btn-features-fr.svg" alt="Fonctions" height="40"></a>&nbsp;
<a href="#deux-versions"><img src="docs/assets/btn-builds-fr.svg" alt="Deux versions" height="40"></a>&nbsp;
<a href="#compiler-depuis-les-sources"><img src="docs/assets/btn-source-fr.svg" alt="Compiler" height="40"></a>
<br><br>
<a href="https://ko-fi.com/adrbn"><img src="docs/assets/btn-tip-fr.svg" alt="Offrir un café sur Ko-fi" height="64"></a>

<br>

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-EB534D?style=flat-square&labelColor=121212&logo=apple&logoColor=white)](#configuration-requise)
[![watchOS 26+](https://img.shields.io/badge/watchOS-26%2B-EB534D?style=flat-square&labelColor=121212&logo=apple&logoColor=white)](#configuration-requise)
[![Navidrome / Subsonic](https://img.shields.io/badge/serveur-Navidrome%20%2F%20Subsonic-EB534D?style=flat-square&labelColor=121212)](#configuration-requise)
[![Aucun pistage](https://img.shields.io/badge/pistage-aucun-EB534D?style=flat-square&labelColor=121212)](#confidentialit%C3%A9)
[![Dernière version](https://img.shields.io/github/v/release/adrbn/aura?include_prereleases&style=flat-square&labelColor=121212&color=EB534D&label=version)](https://github.com/adrbn/aura/releases/latest)
[![Licence GPL-3.0](https://img.shields.io/badge/licence-GPL--3.0-EB534D?style=flat-square&labelColor=121212)](LICENSE)

<sub>App Store : bientôt, sous le nom <b>Aura: Self-Hosted Music</b> · Gratuit et libre · Apportez votre serveur</sub>

[English](README.md) · Français

</div>

---

Aura lit la musique de votre propre serveur. Branchez-le sur Navidrome, ou sur n'importe quel serveur qui parle l'API
Subsonic, et votre bibliothèque est dans votre iPhone : en qualité d'origine, avec les paroles en rythme, des mix tirés
de ce que vous écoutez vraiment, un Radar des sorties de vos artistes, et tout ce que vous avez téléchargé toujours là
quand le réseau tombe. Sur l'Apple Watch, c'est une télécommande et une bibliothèque au poignet ; en voiture, CarPlay
reprend le tout.

> **Aura est un client, pas un service de musique.** Il se branche sur un serveur Navidrome ou compatible Subsonic qui
> est à vous, ou auquel vous avez accès. Il lit votre bibliothèque ; il n'héberge pas de musique, n'en fournit pas et
> n'en cherche pas pour vous.

## Ce que fait Aura

<table>
  <tr>
    <td align="center" valign="top" width="33%"><img src="docs/assets/card-eq.svg" alt="La courbe d'un égaliseur cinq bandes qui passe d'un préréglage à l'autre" width="100%"><br><b>Sans perte, avec un vrai égaliseur</b><br><sub>Le FLAC et l'ALAC restent sans perte, ou en 128, 192 ou 320 kbit/s sur une connexion lente. Cinq bandes de 60 Hz à 14 kHz, une seule courbe à tirer, 15 préréglages, ReplayGain.</sub></td>
    <td align="center" valign="top" width="33%"><img src="docs/assets/card-lyrics.svg" alt="L'écran des paroles, capturé dans l'app" width="100%"><br><b>Les paroles en rythme</b><br><sub>Mot à mot quand votre serveur a le minutage de chaque mot, ligne par ligne sinon. D'abord votre serveur, puis <a href="https://lrclib.net">LRCLIB</a>. Touchez une ligne pour y sauter.</sub></td>
    <td align="center" valign="top" width="33%"><img src="docs/assets/card-mixes.svg" alt="Des pochettes Pour vous de l'app qui défilent" width="100%"><br><b>Pour vous</b><br><sub>Des mix selon l'heure, l'humeur et le genre, chacun avec sa pochette. Le Mix instantané lance une radio depuis n'importe quel morceau ou artiste. Le Wrapped fait le bilan de votre année, calculé sur l'iPhone.</sub></td>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/assets/card-radar.svg" alt="Le Radar qui liste les nouveautés de vos artistes, capturé dans l'app" width="100%"><br><b>Radar</b><br><sub>Les sorties du mois des artistes que vous écoutez le plus. Ce que votre serveur a se lit en entier ; le reste, en extraits de 30 secondes.</sub></td>
    <td align="center" valign="top"><img src="docs/assets/card-offline.svg" alt="Un album téléchargé, capturé dans l'app" width="100%"><br><b>Tout, hors ligne</b><br><sub>Téléchargez un morceau, un album, une playlist ou toute la bibliothèque, chacun dans sa qualité. Sans réseau, la bibliothèque, la recherche et la lecture continuent.</sub></td>
    <td align="center" valign="top"><img src="docs/assets/card-devices.svg" alt="L'app Apple Watch et l'iPhone qui jouent le même morceau, tous deux capturés dans l'app" width="100%"><br><b>Apple Watch et CarPlay</b><br><sub>En cours de lecture, les paroles, la file d'attente et la bibliothèque au poignet, la Digital Crown sur le volume. CarPlay dans la version App Store.</sub></td>
  </tr>
</table>

**Et aussi**

- **Une file d'attente modifiable.** Lire ensuite, ajouter à la fin, glisser pour réordonner. Quand elle se vide, la lecture automatique enchaîne sur des morceaux proches.
- **Lecture aléatoire, répétition d'un morceau ou de tout, et un minuteur de veille** qui coupe après un temps donné ou à la fin du morceau.
- **Scrobbling.** Les écoutes partent vers votre serveur, et l'iPhone les garde en attendant quand vous êtes hors ligne.
- **Des paroles que vous pouvez corriger.** Décalez le minutage si votre casque Bluetooth est en retard, ou calez vous-même les paroles d'un morceau : touchez *Now* au début de chaque ligne marquée. Votre minutage reste sur l'iPhone et passe avant toutes les autres sources. Pour un duo, un remix ou une autre version, Aura vérifie que les paroles correspondent à la version qui joue.
- **La traduction des paroles**, en option, sous chaque ligne, par Gemini de Google avec votre propre clé d'API gratuite (Settings → Lyrics → Translation). Un morceau n'est envoyé que quand vous touchez traduire, et seulement ses lignes, son titre et son artiste. Les traductions sont gardées pour l'écoute hors ligne.
- **Enregistrer une radio comme playlist** sur votre serveur, pochette comprise.
- **Une seule recherche** dans les morceaux, albums, artistes et playlists, qui pardonne les fautes de frappe, avec des Recherches récentes de ce que vous avez écouté.
- **Des playlists à votre façon.** En grille ou en liste, filtrées par épinglées, radios, mix, les vôtres, partagées ou téléchargées. Créez-les, réordonnez-les, donnez-leur une pochette tirée de vos photos ; les changements partent sur votre serveur.
- **Des pages aux couleurs de leur pochette.** Quand votre serveur n'a pas la pochette d'un album, Aura la trouve dans le catalogue de Deezer.
- **Un cache de streaming.** Ce que vous écoutez en streaming est gardé au fil de la lecture, jusqu'à la taille que vous fixez, et un mode hors ligne que vous activez le reste d'un lancement à l'autre.
- **Plusieurs serveurs**, qu'on change depuis le titre de l'accueil, et des bibliothèques réparties en dossiers de musique.
- **Sur l'écran verrouillé**, dans le Centre de contrôle et dans la Dynamic Island, avec AirPlay.
- **Siri et Raccourcis** en anglais et en français : lecture, pause, morceau suivant ou précédent, aléatoire, répétition, mettre un morceau en favori, lancer une playlist ou un album par son nom, ou vos favoris.
- **Des liens de partage.** Partagez un morceau sous forme de liens qui l'ouvrent sur d'autres services.
- **À votre goût.** Clair ou sombre, la couleur d'accent de votre choix, et les onglets et les sections de l'accueil dans l'ordre que vous voulez.
- **Une horloge de chevet** (l'horloge en paysage). Activez-la, tournez le téléphone sur le côté pendant la lecture, et la pochette, l'heure ou les paroles remplissent l'écran.

## Captures d'écran

<p align="center">
  <img src="docs/assets/shot-1-hero.webp" width="200" alt="En cours de lecture, aux couleurs de l'album" />
  <img src="docs/assets/shot-2-mixes.webp" width="200" alt="L'accueil avec le Wrapped de l'année, les mix Pour vous et les artistes favoris" />
  <img src="docs/assets/shot-3-radio.webp" width="200" alt="Une radio lancée depuis un morceau, avec sa pochette et Lecture, Aléatoire et Enregistrer comme playlist" />
  <img src="docs/assets/shot-4-lyrics.webp" width="200" alt="Des paroles synchronisées sur la pochette floutée" />
</p>
<p align="center">
  <img src="docs/assets/shot-5-artist.webp" width="200" alt="Une page d'artiste avec le nombre d'écoutes, le Mix instantané, l'aléatoire et les titres phares" />
  <img src="docs/assets/shot-6-library.webp" width="200" alt="L'onglet Bibliothèque : morceaux, albums, favoris, genres, artistes et Radar" />
  <img src="docs/assets/shot-7-anywhere.webp" width="200" alt="Les téléchargements, CarPlay et l'Apple Watch" />
  <img src="docs/assets/shot-8-private.webp" width="200" alt="Pas de compte, pas de pistage" />
</p>
<p align="center">
  <img src="docs/assets/watch-1-now-playing.webp" width="180" alt="Apple Watch : En cours de lecture, les commandes sur la pochette floutée" />
  <img src="docs/assets/watch-2-lyrics.webp" width="180" alt="Apple Watch : les paroles" />
  <img src="docs/assets/watch-3-up-next.webp" width="180" alt="Apple Watch : la file d'attente" />
  <img src="docs/assets/watch-4-library.webp" width="180" alt="Apple Watch : la bibliothèque avec la recherche et Pour vous" />
</p>

## Deux versions

Les deux sont gratuites, et tout ce qui n'est pas listé ici est identique dans les deux.

| | Version App Store | IPA à installer soi-même |
|---|---|---|
| CarPlay | Oui | Non : re-signer l'IPA fait perdre l'autorisation CarPlay d'Apple |
| Get It (Soulseek via votre propre [slskd](https://github.com/slskd/slskd)) | Non | À activer, dans Settings → Beta Features |
| Vérification NetEase du minutage des paroles pour les remix et les versions modifiées | Non | Oui |

**Get It** va chercher ce qui manque à votre bibliothèque : une sortie du Radar, un résultat Deezer dans la recherche,
les morceaux manquants d'un album que vous n'avez qu'en partie (un par un, ou avec Get All), ou le cœur sur un extrait
dans En cours de lecture. Aura trouve la sortie sur Soulseek via votre slskd, la télécharge et attend que votre serveur
l'ajoute, avec une carte au-dessus du mini-lecteur et une Activité en direct qui suit chaque étape. Rien ne passe par le
serveur de quelqu'un d'autre. Ne téléchargez que la musique que vous avez le droit d'avoir.

La **vérification NetEase** demande au catalogue de NetEase, par titre, artiste et durée, des paroles minutées sur
l'enregistrement exact, parce que les sources de paroles rangent souvent un remix sous le minutage de l'original.

La version à installer soi-même peut aussi suivre une liste de suivi SoulSync depuis le Radar, et écrire sur votre
serveur, en fichiers `.lrc` via File Browser, les paroles que vous avez calées à la main.

## Installation

### Installer l'IPA soi-même

1. Installez un outil de sideload sur votre iPhone : [AltStore](https://altstore.io), [SideStore](https://sidestore.io) ou Feather.
2. Téléchargez `Aura-v<version>.ipa` depuis la [dernière version](https://github.com/adrbn/aura/releases/latest). Chaque version indique sa somme de contrôle SHA-256.
3. Ouvrez l'IPA dans votre outil de sideload et installez-le.
4. Au premier lancement, iOS bloque l'app : allez dans **Réglages → Général → VPN et gestion de l'appareil** et faites confiance au profil du développeur.
5. Ouvrez Aura et saisissez l'adresse de votre serveur, votre nom d'utilisateur et votre mot de passe.

Installer un nouvel IPA par-dessus un ancien garde vos serveurs, mots de passe, téléchargements et épingles. Avec un
identifiant Apple gratuit, la signature expire au bout de 7 jours et l'outil de sideload doit la renouveler ; c'est une
limite d'iOS, pas d'Aura.

### App Store

Aura est en cours d'examen par Apple sous le nom **Aura: Self-Hosted Music**. L'app sera gratuite, sans achats intégrés.

## Configuration requise

- Un iPhone sous iOS 26 ou plus récent.
- Une Apple Watch sous watchOS 26 ou plus récent, pour l'app de la montre.
- Un serveur [Navidrome](https://www.navidrome.org), ou n'importe quel serveur qui parle l'API Subsonic 1.16.1. Les extensions OpenSubsonic sont utilisées quand le serveur les propose.

Pas encore de serveur ? Essayez Aura avec la démo publique de Navidrome : `https://demo.navidrome.org`, utilisateur
`demo`, mot de passe `demo`.

## Compiler depuis les sources

```bash
git clone https://github.com/adrbn/aura
cd aura
open Aura/Aura.xcodeproj
```

- Xcode 26 ou plus récent (les archives App Store sont faites avec Xcode 26.6).
- Choisissez votre propre équipe dans Signing & Capabilities, et donnez au réglage de build `AURA_BUNDLE_BASE`, au niveau du projet, un identifiant de bundle qui vous appartient. Le widget, l'app de la montre et les cibles Mac en tirent le leur.
- Schémas et configurations :
  - **Aura**, avec `Debug` et `Release` : la version à installer soi-même, avec Get It et la vérification NetEase.
  - **Aura-AppStore**, avec `Release-AppStore` : compilée avec le drapeau `APPSTORE_BUILD`, qui retire les fonctions réservées au sideload.
  - **Aura-mac** : un aperçu macOS ; seul l'iPhone est testé au quotidien.
- CarPlay demande l'autorisation `carplay-audio` d'Apple sur votre propre équipe.
- `scripts/watch-screenshots.sh` dessine les pages de l'app de la montre sur un Mac, sans montre ni simulateur.

Les polices (Vavin et Archivo, toutes deux sous SIL OFL 1.1) sont dans le dépôt : un clone tout neuf compile sans rien
ajouter.

Les illustrations de cette page sont faites par [`docs/assets/make_svgs.py`](docs/assets/make_svgs.py) (Python,
bibliothèque standard seulement) : `python3 docs/assets/make_svgs.py` régénère tous les SVG. Toutes les illustrations
intègrent de vraies captures de l'app, gardées en petit dans `docs/assets/readme-src/`.

## Confidentialité

Aura n'a pas de compte ni de statistiques d'usage, et n'envoie rien au développeur. Les mots de passe des serveurs sont
gardés dans le trousseau d'iOS. L'app parle à votre serveur et aux services publics listés dans la
[politique de confidentialité](https://adrbn.github.io/aura-site/privacy.html), qui dit exactement ce que chacun reçoit :
paroles, crédits, pochettes, photos d'artistes, le Radar et les liens de partage.

## Contribuer

Bugs et demandes de fonctions : [github.com/adrbn/aura/issues](https://github.com/adrbn/aura/issues). Les pull requests
sont les bienvenues. Le [journal des modifications](CHANGELOG.md) (en anglais) dit ce qui a changé et pourquoi.

## Soutenir

Aura est gratuit, et le restera. S'il mérite sa place sur votre écran d'accueil :

<a href="https://ko-fi.com/adrbn"><img src="docs/assets/btn-tip-fr.svg" height="64" alt="Offrir un café sur Ko-fi"></a>

Une étoile sur le dépôt aide aussi d'autres personnes à le trouver.

## Licence

[GPL-3.0](LICENSE) © 2026 adrbn. Vous pouvez partager et modifier Aura sous la même licence ; une version modifiée que
vous distribuez doit rester ouverte, sous GPL-3.0.

## Crédits

- [LRCLIB](https://lrclib.net) pour les paroles, [MusicBrainz](https://musicbrainz.org) pour les crédits des morceaux, le catalogue public de [Deezer](https://www.deezer.com) pour les pochettes, les photos d'artistes, le Radar et les extraits, et l'API iTunes Search pour les liens de partage.
- En option, avec votre propre clé : [Google Gemini](https://ai.google.dev) pour la traduction des paroles et [Last.fm](https://www.last.fm) pour les statistiques d'écoute.
- Polices : [Archivo](https://github.com/Omnibus-Type/Archivo) et Vavin, toutes deux sous SIL Open Font License 1.1.
- Toutes les illustrations de cette page sont de vraies captures de l'app, sur la bibliothèque du développeur.

<sub>Aura n'est affilié ni à Navidrome, ni à Subsonic, ni à Apple. Toutes les marques appartiennent à leurs propriétaires respectifs.</sub>
