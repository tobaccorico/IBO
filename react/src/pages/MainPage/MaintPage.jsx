
import React from 'react'
import { Mint } from '../../components/Mint'
import { MintBar } from '../../components/MintBar'

import './MaintPage.scss'

const MaintPage = () => {
  return (
    <React.Fragment>
      <div className="main-side">
        <MintBar />
      </div>
      <div className="main-content">
        <div className="main-mintContainer">
          <Mint />
        </div>
      </div>
      <div className="main-fakeCol" />
    </React.Fragment>
  )
}

export default MaintPage