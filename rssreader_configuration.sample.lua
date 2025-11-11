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
            name = "My FreshRSS", -- You can set a custom name
            type = "freshrss",
            active = true, -- Set to true to enable this account
            auth = {
                base_url = "https://your-freshrss-domain.com", -- Your server URL
                username = "your_freshrss_username",
                password = "your_api_password", -- Get this from FreshRSS > Profile > API Password
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
    sanitizers = { -- available types = fivefilters, diffbot
        {  
            order = 1,  
            type = "fivefilters",  
            active = false,  
            base_url = "https://rss.com",  -- your self host ftr instance
        }, 
        {  
            order = 2,  
            type = "fivefilters",  
            active = false,  
        }, 
        {
            order = 3,
            type = "diffbot",
            active = false,
            token = "your_diffbot_token", -- get your token here: https://app.diffbot.com/
        },
    },
    features = {
        default_folder_on_save = nil, -- set a folder to save new feeds to, if nil then default is home folder
        download_images_when_sanitize_successful = true, -- if sanitize functionality is successful, download images
        download_images_when_sanitize_unsuccessful = false, -- if sanitize functionality is unsuccessful, download images (for the original html file)
        show_images_in_preview = true, -- show images in preview screen
    },
}