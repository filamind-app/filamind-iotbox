/* global owl */
/*
 * Modified by filamind-app: adds a "Server URL" tab so the IoT Box can be
 * connected directly to a self-hosted Odoo server, bypassing the
 * iot-proxy.odoo.com pairing exchange.
 *
 * Source of truth: this file is replaced wholesale by scripts/build-image.sh.
 * The matching unified diff lives at patches/003-server-dialog-url-input.patch
 * for reference and CI sanity-checking.
 */

import useStore from "../../hooks/useStore.js";
import { BootstrapDialog } from "./BootstrapDialog.js";
import { LoadingFullScreen } from "../LoadingFullScreen.js";

const { Component, xml, useState } = owl;

export class ServerDialog extends Component {
    static props = {};
    static components = { BootstrapDialog, LoadingFullScreen };

    setup() {
        this.store = useStore();
        this.state = useState({
            waitRestart: false,
            loading: false,
            error: null,
            mode: "url",
        });
        this.form = useState({ token: "", url: "", code: "" });
    }

    async connectToServer() {
        this.state.loading = true;
        this.state.error = null;
        const params = this.state.mode === "url"
            ? { url: this.form.url, code: this.form.code }
            : { token: this.form.token };
        try {
            const data = await this.store.rpc({
                url: "/iot_drivers/connect_to_server",
                method: "POST",
                params,
            });

            if (data.status === "success") {
                this.state.waitRestart = true;
            } else {
                this.state.error = data.message;
            }
        } catch {
            console.warn("Error while fetching data");
        }
        this.state.loading = false;
    }

    async clearConfiguration() {
        this.state.waitRestart = true;
        try {
            await this.store.rpc({
                url: "/iot_drivers/server_clear",
            });
        } catch {
            console.warn("Error while clearing configuration");
        }
    }

    static template = xml`
    <t t-translation="off">
        <LoadingFullScreen t-if="this.state.waitRestart">
            <t t-set-slot="body">
                Updating Odoo Server information, please wait...
            </t>
        </LoadingFullScreen>

        <BootstrapDialog identifier="'server-configuration'" btnName="'Configure'">
            <t t-set-slot="header">
                Configure Odoo Database
            </t>
            <t t-set-slot="body">
                <t t-if="!store.base.server_status">
                    <ul class="nav nav-tabs mb-3" role="tablist">
                        <li class="nav-item" role="presentation">
                            <button type="button"
                                    class="nav-link"
                                    t-att-class="{ active: state.mode === 'url' }"
                                    t-on-click="() => state.mode = 'url'">
                                Server URL
                            </button>
                        </li>
                        <li class="nav-item" role="presentation">
                            <button type="button"
                                    class="nav-link"
                                    t-att-class="{ active: state.mode === 'token' }"
                                    t-on-click="() => state.mode = 'token'">
                                Pairing Token
                            </button>
                        </li>
                    </ul>

                    <div t-if="state.mode === 'url'">
                        <div class="alert alert-info fs-6" role="alert">
                            Enter the URL of your self-hosted Odoo server (running the
                            <b>filamind-iot</b> addon) and the pairing code shown by
                            <i>IoT → Connect IoT Box</i> there. No <code>iot-proxy.odoo.com</code>
                            round-trip.
                        </div>
                        <div class="input-group-sm mb-2">
                            <span class="input-group-text" style="min-width:5rem;">URL</span>
                            <input type="url" class="form-control"
                                   t-model="form.url"
                                   placeholder="https://odoo.example.com"/>
                        </div>
                        <div class="input-group-sm mb-3">
                            <span class="input-group-text" style="min-width:5rem;">Code</span>
                            <input type="text" class="form-control text-uppercase"
                                   t-model="form.code"
                                   maxlength="16"
                                   placeholder="8-char pairing code (optional)"/>
                        </div>
                        <div class="form-text small">
                            Leave the code empty to save the URL only — useful if you plan
                            to pair from the Odoo side using <i>box-token</i> mode.
                        </div>
                    </div>

                    <div t-if="state.mode === 'token'">
                        <div class="alert alert-warning fs-6 pb-0" role="alert">
                            <ol>
                                <li>Install <b>IoT App</b> on your database,</li>
                                <li>From the IoT App click on <b>Connect</b> button.</li>
                            </ol>
                        </div>
                        <div class="input-group-sm mb-3">
                            <input type="text" class="form-control"
                                   t-model="form.token"
                                   placeholder="Server token"/>
                        </div>
                    </div>
                </t>
                <t t-else="">
                    <div class="small">
                        <p class="m-0">
                            Your current database is: <br/>
                            <strong t-esc="store.base.server_status" />
                        </p>
                    </div>
                </t>

                <div class="text-danger small mt-2" t-if="state.error" t-esc="state.error" />
            </t>
            <t t-set-slot="footer">
                <button type="submit"
                        class="btn btn-primary btn-sm"
                        t-if="!store.base.server_status"
                        t-on-click="connectToServer"
                        t-att-disabled="state.loading or
                                        (state.mode === 'url' and !form.url) or
                                        (state.mode === 'token' and !form.token)">
                    Connect
                </button>
                <button type="button" class="btn btn-danger btn-sm" t-if="store.base.server_status" t-on-click="clearConfiguration">Disconnect</button>
                <button type="button" class="btn btn-secondary btn-sm" data-bs-dismiss="modal">Close</button>
            </t>
        </BootstrapDialog>
    </t>
    `;
}
