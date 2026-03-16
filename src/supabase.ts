import { createClient, SupabaseClient } from "@supabase/supabase-js";
import { Notice } from "obsidian";

export type SyncStatus = "offline" | "synced" | "syncing" | "error";

const STATUS_LABEL: Record<SyncStatus, string> = {
	offline: "🔴 Offline",
	synced: "🟢 Synced",
	syncing: "🔄 Syncing",
	error: "⚠️ Error",
};

export interface SupabaseHost {
	settings: {
		supabaseUrl: string;
		supabaseAnonKey: string;
		email: string;
		password: string;
	};
	statusBarItem: HTMLElement;
}

export class SupabaseManager {
	client: SupabaseClient | null = null;
	private host: SupabaseHost;
	private channels: ReturnType<SupabaseClient["channel"]>[] = [];
	private syncIntervals: number[] = [];

	constructor(host: SupabaseHost) {
		this.host = host;
	}

	setStatus(status: SyncStatus): void {
		this.host.statusBarItem.setText(STATUS_LABEL[status]);
	}

	async init(): Promise<void> {
		const { supabaseUrl, supabaseAnonKey, email } = this.host.settings;

		if (!supabaseUrl || !supabaseAnonKey || !email) {
			this.setStatus("offline");
			return;
		}

		let parsedUrl: URL;
		try {
			parsedUrl = new URL(supabaseUrl);
		} catch {
			this.setStatus("error");
			new Notice(
				"SupaBase Jump: Project URL is not a valid URL — check your settings.",
			);
			return;
		}

		if (!parsedUrl.hostname.endsWith(".supabase.co")) {
			console.warn(
				"SupaBase Jump: Project URL does not look like a Supabase URL:",
				supabaseUrl,
			);
		}

		try {
			this.client = createClient(supabaseUrl, supabaseAnonKey, {
				auth: {
					persistSession: true,
					autoRefreshToken: true,
					detectSessionInUrl: false,
				},
			});
			await this.signIn();
		} catch (err) {
			console.error("SupaBase Jump: init error", err);
			this.client = null;
			this.setStatus("error");
			const msg = err instanceof Error ? err.message : String(err);
			new Notice(`SupaBase Jump: connection failed — ${msg}`, 8000);
		}
	}

	/**
	 * Attempts signInWithPassword. Falls back to signUp when Supabase returns
	 * "invalid_credentials" — this covers the first-run case on projects where
	 * email confirmation is disabled.
	 *
	 * Network-level throws (e.g. "Failed to fetch" when the project is paused
	 * or the URL is unreachable) are re-thrown as plain Errors so init()'s
	 * catch block can surface them in the Notice.
	 */
	async signIn(): Promise<void> {
		if (!this.client) return;

		const { email, password } = this.host.settings;
		if (!email || !password) {
			this.setStatus("offline");
			new Notice("SupaBase Jump: email and password are required.");
			return;
		}

		let signInResult: Awaited<
			ReturnType<SupabaseClient["auth"]["signInWithPassword"]>
		>;
		try {
			signInResult = await this.client.auth.signInWithPassword({
				email,
				password,
			});
		} catch (err) {
			// Network error (project paused, DNS failure, CORS, etc.)
			const msg = err instanceof Error ? err.message : String(err);
			throw new Error(`network error during sign-in — ${msg}`);
		}

		const { error } = signInResult;

		if (!error) {
			this.setStatus("synced");
			new Notice("SupaBase Jump: connected.");
			return;
		}

		// Email exists but awaiting confirmation (returned on repeat sign-in
		// attempts after a sign-up where email confirmation is enabled).
		if (error.code === "email_not_confirmed") {
			this.setStatus("offline");
			new Notice(
				"SupaBase Jump: email not confirmed.\n\n" +
					"Check your inbox and click the confirmation link, then press Connect again.\n\n" +
					'Or disable email confirmation: Supabase \u2192 Authentication \u2192 Providers \u2192 Email \u2192 uncheck "Confirm email".',
				12000,
			);
			return;
		}

		// First-run: account doesn't exist yet — try to create one.
		if (error.code === "invalid_credentials") {
			let signUpResult: Awaited<
				ReturnType<SupabaseClient["auth"]["signUp"]>
			>;
			try {
				signUpResult = await this.client.auth.signUp({
					email,
					password,
				});
			} catch (err) {
				const msg = err instanceof Error ? err.message : String(err);
				throw new Error(`network error during sign-up — ${msg}`);
			}

			if (signUpResult.error) {
				console.error(
					"SupaBase Jump: sign-up failed",
					signUpResult.error,
				);
				this.setStatus("error");
				new Notice(
					`SupaBase Jump: sign-up failed — ${signUpResult.error.message}`,
				);
				return;
			}

			// Account created — check whether email confirmation is required.
			const confirmed = signUpResult.data.user?.confirmed_at;
			if (!confirmed) {
				// Supabase sent a confirmation email; the session is not active yet.
				this.setStatus("offline");
				new Notice(
					"SupaBase Jump: account created — confirmation email sent.\n\n" +
						"Click the link in the email, then press Connect.\n\n" +
						'Tip: disable email confirmation in Supabase \u2192 Authentication \u2192 Providers \u2192 Email \u2192 uncheck "Confirm email" to skip this step.',
					12000,
				);
			} else {
				this.setStatus("synced");
				new Notice("SupaBase Jump: account created and connected.");
			}
			return;
		}

		// Any other auth error (wrong password, account disabled, etc.)
		console.error("SupaBase Jump: sign-in failed", error);
		this.setStatus("error");
		new Notice(`SupaBase Jump: sign-in failed — ${error.message}`);
	}

	async signOut(): Promise<void> {
		if (!this.client) return;
		await this.client.auth.signOut();
		this.setStatus("offline");
		new Notice("SupaBase Jump: signed out.");
	}

	// ── Registration helpers (for future sync code) ───────────────────────────

	/** Track a realtime channel so cleanup() can unsubscribe it. */
	registerChannel(channel: ReturnType<SupabaseClient["channel"]>) {
		this.channels.push(channel);
		return channel;
	}

	/** Track a setInterval ID so cleanup() can clear it. */
	registerSyncInterval(id: number) {
		this.syncIntervals.push(id);
		return id;
	}

	// ── Cleanup ───────────────────────────────────────────────────────────────

	cleanup(): void {
		// Unsubscribe and remove all realtime channels.
		if (this.client) {
			this.client.removeAllChannels();
		}
		this.channels = [];

		// Clear all background sync intervals.
		this.syncIntervals.forEach((id) => window.clearInterval(id));
		this.syncIntervals = [];

		this.client = null;
		this.setStatus("offline");
	}
}
