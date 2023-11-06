/*
 * Base class for core services.
 */
@Abstract
@WebService("")
service CoreService {
    construct() {
        accountManager = ControllerConfig.accountManager;
        hostManager    = ControllerConfig.hostManager;
    }

    /**
     * The account manager.
     */
    protected AccountManager accountManager;

    /**
     * The host manager.
     */
    protected HostManager hostManager;

    /**
     * The current account name.
     */
    String accountName.get() {
        assert SessionData session := this.session.is(SessionData);
        return session.accountName? : "";
    }
}