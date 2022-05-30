import ecstasy.mgmt.Container;

import ecstasy.reflect.FileTemplate;

import common.WebHost;
import common.ErrorLog;
import common.HostManager;

import web.Consumes;
import web.Get;
import web.HttpStatus;
import web.PathParam;
import web.Post;
import web.Produces;
import web.QueryParam;
import web.WebServer;
import web.WebServer.Handler;

@web.LoginRequired
@web.WebService("/host")
service Controller(HostManager mgr)
    {
    /**
     * The host manager.
     */
    private HostManager mgr;

    @Get("/userId")
    String getUserId()
      {
      // TODO: session attribute
      return "acme";
      }

    @Post("/load")
    (HttpStatus, String) load(@QueryParam("app") String appName, @QueryParam String domain)
        {
        // there is one and only one application per [sub] domain
        if (mgr.getWebHost(domain))
            {
            return HttpStatus.OK, $"http://{domain}.xqiz.it:8080";
            }

        // temporary hack: it will be another argument:
        //    @SessionParam("userId") String userId
        // which will map to an account
        String account = "acme";

        Directory userDir = getUserHomeDirectory(account);
        ErrorLog  errors  = new ErrorLog();

        if (WebHost webHost := mgr.createWebHost(userDir, appName, domain, errors))
            {
            try
                {
                webHost.container.invoke("createCatalog_", Tuple:(webHost.httpServer));

                return HttpStatus.OK, $"http://{domain}.xqiz.it:8080";
                }
            catch (Exception e)
                {
                webHost.close(e);
                mgr.removeWebHost(webHost);
                }
            }
        return HttpStatus.NotFound, errors.toString();
        }

    @Get("/report/{domain}")
    @Produces("application/json")
    String report(@PathParam String domain)
        {
        String response;
        if (WebHost webHost := mgr.getWebHost(domain))
            {
            Container container = webHost.container;
            response = $"{container.status} {container.statusIndicator}";
            }
        else
            {
            response = "Not loaded";
            }
        return response.quoted();
        }

    @Post("/unload/{domain}")
    HttpStatus unload(@PathParam String domain)
        {
        if (WebHost webHost := mgr.getWebHost(domain))
            {
            mgr.removeWebHost(webHost);
            webHost.close();

            return HttpStatus.OK;
            }
        return HttpStatus.NotFound;
        }

    @Post("/debug")
    HttpStatus debug()
        {
        // temporary; TODO: remove
        assert:debug;
        return HttpStatus.OK;
        }

    // ----- helpers -------------------------------------------------------------------------------

    /**
     * Get a user directory for the specified account.
     */
    private Directory getUserHomeDirectory(String account)
        {
        // temporary hack
        @Inject Directory homeDir;
        Directory accountDir = homeDir.dirFor($"xqiz.it/platform/{account}");
        accountDir.ensure();
        return accountDir;
        }
    }