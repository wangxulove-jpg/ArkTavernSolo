import { createRouter, createWebHashHistory } from 'vue-router'

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', name: 'home', component: () => import('./views/HomeView.vue') },
    { path: '/editor', name: 'editor', component: () => import('./views/EditorView.vue') },
    { path: '/adapt', name: 'adapt', component: () => import('./views/AdaptView.vue') },
    { path: '/settings', name: 'settings', component: () => import('./views/SettingsView.vue') }
  ]
})
