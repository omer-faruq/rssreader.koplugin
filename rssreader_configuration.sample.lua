return {
    accounts = {
        {
            name = "NewsBlur 1", -- you can set a custom name
            type = "newsblur",
            active = false, -- set to true to enable this account
            auth = {
                username = "user name",
                password = "password",
            },
        },
        {
            name = "CommaFeed 1", -- you can set a custom name
            type = "commafeed",
            active = false, -- set to true to enable this account
            auth = {
                base_url = "https://www.commafeed.com/rest",
                username = "user name",
                password = "password",
            },
        },
        {
            name = "Sample", -- you can set a custom name but also rename in rssreader_local_defaults.lua
            type = "local",
            active = true, -- set to true to enable this account
        },
        {
            name = "Local 2", -- you can set a custom name but also rename in rssreader_local_defaults.lua
            type = "local",
            active = false, -- set to true to enable this account
        },
    },
    features = {
        default_folder_on_save = nil, -- set a folder to save new feeds to, if nil then default is home folder
        use_fivefilters_on_save_open = true, --try to use fivefilters on save and open a website to sanitize it
    },
}