/**
 * Shortcut Manager
 * Handles loading, displaying, and managing shortcuts.
 * Supports both Electron (via preload) and Browser (via fetch) modes.
 */

// Polyfill window.shortcuts if not in Electron or if strictly using Python Server
// This allows the user's requested structure: window.shortcuts.list()
if (!window.shortcuts) {
    const SERVER_URL = 'http://localhost:5000';

    window.shortcuts = {
        list: async () => {
            try {
                const res = await fetch(`${SERVER_URL}/shortcuts`);
                const data = await res.json();
                if (data.status === 'success') {
                    // Convert simple filenames to object structure if needed, or just return filenames
                    // The backend returns { shortcuts: ["file.lnk", ...] }
                    return data.shortcuts.map(f => ({
                        name: f.replace('.lnk', ''),
                        filename: f,
                        fullPath: f // For server backend, filename is enough
                    }));
                }
                return [];
            } catch (e) {
                console.error("Failed to list shortcuts:", e);
                return [];
            }
        },

        open: async (filename) => {
            try {
                // If it's a filename (from list), use launch-lnk
                // If it's a full path (legacy), use launch
                const endpoint = filename.endsWith('.lnk') ? '/launch-lnk' : '/launch';
                const body = filename.endsWith('.lnk') ? { filename } : { path: filename };

                await fetch(`${SERVER_URL}${endpoint}`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body)
                });
            } catch (e) {
                console.error("Failed to open shortcut:", e);
            }
        },

        upload: async (file) => {
            const formData = new FormData();
            formData.append('file', file);
            const res = await fetch(`${SERVER_URL}/upload`, { method: 'POST', body: formData });
            return await res.json();
        },

        delete: async (filename) => {
            await fetch(`${SERVER_URL}/delete-shortcut`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ filename: filename })
            });
        }
    };
}

// MAIN LOGIC
async function loadShortcuts() {
    console.log("Loading Shortcuts...");
    const container = document.getElementById("shortcuts-grid-container");
    if (!container) return;

    // Clear existing dynamic shortcuts (keep the "Add New" button if possible, or just rebuild all)
    // Strategy: We want to keep the "Add New" button which is hardcoded in HTML? 
    // actually previous HTML had it hardcoded. Let's look at the structure.
    // Structure: <div class="shortcuts-grid"> <button Browser> <button NEW> </div>
    // We should probably append BEFORE the NEW button, or just manage the list fully.

    // Let's clear SERVER shortcuts but keep System ones?
    // Simplified: Find all buttons with data-role="server-shortcut" and remove them.
    const existing = container.querySelectorAll('[data-role="server-shortcut"]');
    existing.forEach(el => el.remove());

    const shortcuts = await window.shortcuts.list();

    // Find where to insert (before the "NEW" button)
    const addBtn = container.querySelector('[data-role="add-shortcut"]');

    shortcuts.forEach(sc => {
        const btn = document.createElement("button");
        btn.className = "shortcut-btn";
        btn.setAttribute('data-role', 'server-shortcut');
        btn.innerHTML = `<span class="shortcut-icon">lnk</span><span>${sc.name}</span>`;

        // Handle Left Click (Open)
        btn.onclick = () => {
            window.shortcuts.open(sc.filename);
            // Optional: Feedback?
        };

        // Handle Right Click (Delete)
        btn.oncontextmenu = async (e) => {
            e.preventDefault();
            if (confirm(`Delete ${sc.name}?`)) {
                await window.shortcuts.delete(sc.filename);
                loadShortcuts(); // Refresh
            }
        };

        if (addBtn) {
            container.insertBefore(btn, addBtn);
        } else {
            container.appendChild(btn);
        }
    });
}

// Global exposure for AI.html to call if needed, or auto-run
window.loadShortcuts = loadShortcuts;

// Auto-run on load
document.addEventListener('DOMContentLoaded', () => {
    // Initial load
    setTimeout(loadShortcuts, 1000); // Wait bit for server
});

// Expose upload helper for Drag & Drop
window.handleShortcutUpload = async (file) => {
    if (file.name.toLowerCase().endsWith('.lnk')) {
        try {
            const res = await window.shortcuts.upload(file);
            if (res.status === 'success') {
                loadShortcuts();
            }
        } catch (e) {
            console.error("Upload failed", e);
        }
    }
};
