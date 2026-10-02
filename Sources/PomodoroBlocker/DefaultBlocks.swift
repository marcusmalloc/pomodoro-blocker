/// What the block list starts with, and what Restore Defaults brings back.
///
/// The websites come from the pre-made lists in Focuser (https://github.com/aadeshrao123/Focuser, MIT; the notice is in
/// THIRD_PARTY_NOTICES.md), from its social media, videos, games and distractions categories. They're trimmed of sites
/// that are defunct or that people need for work or at home (internet providers, video calls, crowdfunding), and a few
/// obvious gaps are filled in. They're base domains. The blocker adds www. to each, but any other subdomain, like
/// old.reddit.com, has to be listed in its own right because /etc/hosts has no wildcards.
enum DefaultBlocks {
    private static let social = [
        "4chan.org", "9gag.com", "bsky.app", "bsky.social", "discord.com", "discord.gg", "discordapp.com",
        "facebook.com", "m.facebook.com", "fandom.com", "imgur.com", "instagram.com", "line.me", "linkedin.com",
        "mastodon.social", "old.reddit.com", "pinterest.com", "reddit.com", "redd.it", "snapchat.com",
        "telegram.org", "web.telegram.org", "threads.net", "tiktok.com", "truthsocial.com", "tumblr.com",
        "twitter.com", "mobile.twitter.com", "viber.com", "vk.com", "web.whatsapp.com", "weibo.com", "whatsapp.com",
        "x.com",
    ]

    private static let video = [
        "bilibili.com", "crackle.com", "crave.ca", "crunchyroll.com", "dailymotion.com", "disneyplus.com", "fubo.tv",
        "hbomax.com", "hulu.com", "kick.com", "m.youtube.com", "max.com", "netflix.com", "paramountplus.com",
        "peacocktv.com", "philo.com", "primevideo.com", "sling.com", "starz.com", "twitch.tv", "youtu.be",
        "youtube.com",
    ]

    private static let games = [
        "247solitaire.com", "addictinggames.com", "agar.io", "arkadium.com", "armorgames.com", "battle.net",
        "bigfishgames.com", "blizzard.com", "bungie.net", "callofduty.com", "cardgames.io", "chess.com",
        "coolmathgames.com", "crazygames.com", "curseforge.com", "ea.com", "easports.com", "elderscrollonline.com",
        "epicgames.com", "eurogamer.net", "eveonline.com", "finalfantasyxiv.com", "fortnite.com",
        "freeonlinegames.com", "gamehouse.com", "gamesgames.com", "gamesradar.com", "gamespot.com",
        "genshin.hoyoverse.com", "giantbomb.com", "gog.com", "humblebundle.com", "icy-veins.com", "ign.com",
        "itch.io", "kongregate.com", "kotaku.com", "krunker.io", "leagueoflegends.com", "lichess.org",
        "minecraft.net", "miniclip.com", "mmo-champion.com", "modrinth.com", "newgrounds.com", "nexusmods.com",
        "nintendo.com", "onlinegames.com", "pathofexile.com", "pcgamer.com", "playstation.com", "playvalorant.com",
        "pogo.com", "poki.com", "pokemon.com", "polygon.com", "roblox.com", "rockpapershotgun.com",
        "rockstargames.com", "runescape.com", "slither.io", "square-enix.com", "steamcommunity.com",
        "steampowered.com", "store.epicgames.com", "store.steampowered.com", "sudoku.com", "swtor.com",
        "ubisoft.com", "warframe.com", "websudoku.com", "worldofsolitaire.com", "worldoftanks.com", "wowhead.com",
        "xbox.com", "y8.com",
    ]

    static let websites = (social + video + games).sorted()

    /// Apps by bundle identifier, for the ones that can't be relied on to declare a category: game launchers and chat
    /// apps. The identifiers are from Homebrew Cask's metadata, cross-checked against MacUpdater and the macOS Bundle
    /// ID List. They're listed whether or not they're installed, so they're covered from the day they are.
    static let apps: [(name: String, id: String)] = [
        ("Discord", "com.hnc.Discord"),
        ("Telegram", "ru.keepcoder.Telegram"),
        ("WhatsApp", "net.whatsapp.WhatsApp"),
        ("Steam", "com.valvesoftware.steam"),
        ("Epic Games Launcher", "com.epicgames.EpicGamesLauncher"),
        ("Battle.net", "net.battle.bootstrapper"),
        ("GOG Galaxy", "com.gog.galaxy"),
        ("itch", "io.itch.mac"),
        ("Heroic Games Launcher", "com.heroicgameslauncher.hgl"),
        ("GeForce NOW", "com.nvidia.gfnpc.mall"),
        ("Roblox", "com.roblox.RobloxPlayer"),
        ("Minecraft Launcher", "com.mojang.minecraftlauncher"),
        ("League of Legends", "com.riotgames.leagueoflegends"),
    ]

    /// Apple apps that declare themselves social networking, so would be quit at the start of focus, but that most
    /// people want to keep: Messages and FaceTime. They can be put on the list from the + menu.
    static let exemptApps: Set<String> = ["com.apple.MobileSMS", "com.apple.FaceTime"]
}
