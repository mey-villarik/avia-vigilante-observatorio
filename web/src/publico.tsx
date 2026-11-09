import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/app.css';
import './styles/publico.css';
import { Publico } from './views/Publico';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Publico />
  </StrictMode>,
);
